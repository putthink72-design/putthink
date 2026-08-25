import ARKit
import Foundation
import PuttPhysicsKit
import RealityKit
import simd
import UIKit

/// ARKit 메시 + sceneDepth 근접 그리드 표시.
/// 메시 융합이 먼 곳부터 채워지는 ARKit 특성을 보완해, 바닥을 수직·근접으로 비춰도
/// depth 그리드가 즉시 보이게 한다. 물리/앵커에는 주입하지 않는다.
final class BrightMeshVisualizer {
    private final class AnchorEntities {
        let fill: ModelEntity
        let tentativeLines: ModelEntity
        let stableLines: ModelEntity
        var lastRebuild: TimeInterval = 0
        var building = false

        init(fill: ModelEntity, tentativeLines: ModelEntity, stableLines: ModelEntity) {
            self.fill = fill
            self.tentativeLines = tentativeLines
            self.stableLines = stableLines
        }
    }

    private var rootAnchor: AnchorEntity?
    private var entities: [UUID: AnchorEntities] = [:]
    /// ARKit이 한두 프레임 메시 앵커를 비우면 전부 지워지지 않도록 유예.
    private var missingMeshFrames: [UUID: Int] = [:]
    private static let meshMissingGraceFrames = 12
    private var depthGridEntity: ModelEntity?
    private var lastGlobalRebuildTime: TimeInterval = 0
    private var lastDepthRebuildTime: TimeInterval = 0
    private var depthBuilding = false
    private var enabled = false
    private var pipelinePrewarmAnchor: AnchorEntity?

    /// 워밍업 모드 — 지오메트리는 계속 빌드하되 화면에는 표시하지 않음.
    /// 스캔 시작 시 false로 바꾸면 이미 빌드된 메시가 즉시 나타난다.
    var contentHidden = false {
        didSet {
            guard oldValue != contentHidden else { return }
            rootAnchor?.isEnabled = !contentHidden
        }
    }

    private static let tentativeColor = UIColor.systemBlue
    private static let tentativeFillOpacity: Float = 0.5
    private static let stableColor = UIColor.white
    private static let depthGridColor = UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 0.95)
    /// 앵커별 재생성 최소 간격.
    private static let perAnchorRebuildInterval: TimeInterval = 0.55
    private static let maxEdgesPerAnchor = 5_000
    private static let enableFillMesh = false
    /// 거리 무관 고정 반폭(m). 너무 굵으면 바닥을 가림.
    private static let ribbonHalfWidth: Float = 0.0010
    private static let depthGridHalfWidth: Float = 0.0008
    private static let depthSampleCols = 22
    private static let depthSampleRows = 28
    /// depth 유효 거리 (LiDAR 실용 범위).
    private static let depthMinMeters: Float = 0.12
    private static let depthMaxMeters: Float = 4.5

    private let buildQueue = DispatchQueue(label: "trueputt.mesh-build", qos: .userInitiated)

    var lineWidthPixels: Float = 2
    var coverageSnapshot: ScanCoverageSnapshot = .empty
    /// 볼 지정 전 — 메시·depth 그리드를 더 촘촘히 갱신.
    var burstMode = false

    private var globalRebuildInterval: TimeInterval {
        burstMode ? 0.04 : 0.12
    }

    private var depthRebuildInterval: TimeInterval {
        burstMode ? 0.033 : 0.08
    }

    func setEnabled(_ on: Bool, in view: ARView) {
        guard on != enabled else { return }
        enabled = on
        if on {
            let root = AnchorEntity(world: .zero)
            root.isEnabled = !contentHidden
            view.scene.addAnchor(root)
            rootAnchor = root
        } else {
            teardown(in: view)
        }
    }

    /// Metal 파이프라인(머티리얼 셰이더) 사전 컴파일 — 첫 메시 표시 프레임의 히칭 제거.
    /// 카메라 2m 전방 0.5mm 박스(서브픽셀)라 보이지 않지만 항상 프러스텀 안에 있어
    /// 셰이더 컴파일이 확실히 일어난다. 월드 고정 위치는 프러스텀 컬링으로 컴파일이 안 될 수 있음.
    func prewarmRenderPipelines(in view: ARView) {
        guard pipelinePrewarmAnchor == nil else { return }
        let anchor = AnchorEntity(.camera)
        let materials: [RealityKit.Material] = [
            Self.makeLineMaterial(color: Self.tentativeColor),
            Self.makeLineMaterial(color: Self.stableColor),
            Self.makeLineMaterial(color: Self.depthGridColor),
            Self.makeFillMaterial(),
        ]
        for (index, material) in materials.enumerated() {
            let entity = ModelEntity(mesh: .generateBox(size: 0.0005), materials: [material])
            entity.position = SIMD3<Float>(Float(index) * 0.002 - 0.003, 0, -2.0)
            anchor.addChild(entity)
        }
        view.scene.addAnchor(anchor)
        pipelinePrewarmAnchor = anchor
    }

    func teardown(in view: ARView) {
        if let rootAnchor {
            view.scene.removeAnchor(rootAnchor)
        }
        rootAnchor = nil
        entities.removeAll()
        missingMeshFrames.removeAll()
        depthGridEntity = nil
        enabled = false
        coverageSnapshot = .empty
        depthBuilding = false
    }

    func update(in view: ARView) {
        guard enabled, let rootAnchor else { return }
        guard let frame = view.session.currentFrame else { return }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let now = frame.timestamp

        // 1) 매 프레임: transform만 갱신. 앵커가 잠깐 비어도 즉시 삭제하지 않음.
        var liveIDs = Set<UUID>()
        for anchor in meshAnchors {
            liveIDs.insert(anchor.identifier)
            missingMeshFrames[anchor.identifier] = 0
            let transform = Transform(matrix: anchor.transform)
            if let existing = entities[anchor.identifier] {
                existing.fill.transform = transform
                existing.tentativeLines.transform = transform
                existing.stableLines.transform = transform
            } else {
                let entity = makeAnchorEntities(transform: transform, in: rootAnchor)
                entities[anchor.identifier] = entity
            }
        }
        if meshAnchors.isEmpty, !entities.isEmpty {
            // 일시적 공백 — 기존 메시 유지(스캔 시작 직후 깜빡임·소실 방지).
            for id in entities.keys {
                missingMeshFrames[id, default: 0] += 1
            }
        } else {
            for (id, entity) in entities where !liveIDs.contains(id) {
                let misses = (missingMeshFrames[id] ?? 0) + 1
                missingMeshFrames[id] = misses
                guard misses >= Self.meshMissingGraceFrames else { continue }
                entity.fill.removeFromParent()
                entity.tentativeLines.removeFromParent()
                entity.stableLines.removeFromParent()
                entities.removeValue(forKey: id)
                missingMeshFrames.removeValue(forKey: id)
            }
        }

        // 2) sceneDepth 그리드 — 메시 유무·거리와 무관하게 근접 바닥도 표시
        updateDepthGrid(frame: frame, now: now, in: rootAnchor)

        // 3) 메시 앵커 재생성 — 가까운 것 우선, burst에서는 틱당 여러 개 (첫 공개 시 빠른 채움)
        guard !meshAnchors.isEmpty else { return }
        guard now - lastGlobalRebuildTime >= globalRebuildInterval else { return }
        let cameraWorld = frame.camera.transform
        let snapshot = coverageSnapshot
        let camPos = SIMD3<Float>(
            cameraWorld.columns.3.x,
            cameraWorld.columns.3.y,
            cameraWorld.columns.3.z
        )
        let ranked = meshAnchors.enumerated().map { index, anchor -> (Int, Float) in
            let t = anchor.transform.columns.3
            let d = simd_length(SIMD3<Float>(t.x, t.y, t.z) - camPos)
            return (index, d)
        }
        .sorted { $0.1 < $1.1 }

        let rebuildBudget = burstMode ? 4 : 2
        var scheduled = 0
        for rankedEntry in ranked {
            let index = rankedEntry.0
            let anchor = meshAnchors[index]
            guard let entity = entities[anchor.identifier] else { continue }
            let neverBuilt = entity.lastRebuild <= 0
            let intervalOK = neverBuilt || now - entity.lastRebuild >= Self.perAnchorRebuildInterval
            guard !entity.building, intervalOK else { continue }

            entity.building = true
            entity.lastRebuild = now

            guard let snapshotGeo = Self.snapshotGeometry(from: anchor) else {
                entity.building = false
                continue
            }
            let worldTransform = anchor.transform

            buildQueue.async { [weak entity] in
                let split: SplitBuffers
                if snapshot.stableCellCount == 0 {
                    // 첫 공개: 커버리지 분류 생략 — 리본만 빠르게 그림.
                    split = Self.computeFastTentative(
                        positions: snapshotGeo.positions,
                        triangles: snapshotGeo.triangles,
                        worldTransform: worldTransform
                    )
                } else {
                    split = Self.computeSplit(
                        positions: snapshotGeo.positions,
                        triangles: snapshotGeo.triangles,
                        worldTransform: worldTransform,
                        snapshot: snapshot
                    )
                }
                let fillMesh = Self.generateMesh(split.fill, name: "fill")
                let tentativeMesh = Self.generateMesh(split.tentativeLines, name: "blue")
                let stableMesh = Self.generateMesh(split.stableLines, name: "white")
                DispatchQueue.main.async {
                    guard let entity else { return }
                    Self.assign(fillMesh, to: entity.fill)
                    Self.assign(tentativeMesh, to: entity.tentativeLines)
                    Self.assign(stableMesh, to: entity.stableLines)
                    entity.building = false
                }
            }
            scheduled += 1
            if scheduled >= rebuildBudget { break }
        }
        if scheduled > 0 {
            lastGlobalRebuildTime = now
        }
    }

    // MARK: - Depth grid (거리 무관 즉시 피드백)

    private func updateDepthGrid(frame: ARFrame, now: TimeInterval, in root: AnchorEntity) {
        guard !depthBuilding else { return }
        guard now - lastDepthRebuildTime >= depthRebuildInterval else { return }
        guard let depthData = frame.sceneDepth else { return }
        let depthMap = depthData.depthMap
        let camera = frame.camera
        lastDepthRebuildTime = now
        depthBuilding = true

        if depthGridEntity == nil {
            let entity = ModelEntity(
                mesh: .generateBox(size: 0.001),
                materials: [Self.makeLineMaterial(color: Self.depthGridColor)]
            )
            entity.isEnabled = false
            root.addChild(entity)
            depthGridEntity = entity
        }

        buildQueue.async { [weak self] in
            let buffers = Self.buildDepthGridBuffers(
                depthMap: depthMap,
                camera: camera
            )
            let mesh = Self.generateMesh(buffers, name: "depth-grid")
            DispatchQueue.main.async {
                guard let self, let entity = self.depthGridEntity else { return }
                Self.assign(mesh, to: entity)
                self.depthBuilding = false
            }
        }
    }

    private static func buildDepthGridBuffers(
        depthMap: CVPixelBuffer,
        camera: ARCamera
    ) -> GeometryBuffers {
        var result = GeometryBuffers()
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 8, height > 8,
              let base = CVPixelBufferGetBaseAddress(depthMap) else { return result }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let intrinsics = camera.intrinsics
        let fx = intrinsics[0, 0]
        let fy = intrinsics[1, 1]
        let cx = intrinsics[2, 0]
        let cy = intrinsics[2, 1]
        let camToWorld = camera.transform

        let cols = depthSampleCols
        let rows = depthSampleRows
        var samples = [SIMD3<Float>?](repeating: nil, count: cols * rows)

        for row in 0..<rows {
            let v = Int((Float(row) + 0.5) / Float(rows) * Float(height - 1))
            for col in 0..<cols {
                let u = Int((Float(col) + 0.5) / Float(cols) * Float(width - 1))
                let rowPtr = base.advanced(by: v * bytesPerRow)
                    .assumingMemoryBound(to: Float32.self)
                let depth = rowPtr[u]
                guard depth.isFinite,
                      depth >= depthMinMeters,
                      depth <= depthMaxMeters else { continue }
                // depth 카메라: +X 오른쪽, +Y 아래, +Z 전방 → ARKit 카메라(-Z 전방)로 변환
                let x = (Float(u) - cx) * depth / fx
                let y = (Float(v) - cy) * depth / fy
                let camLocal = SIMD4<Float>(x, -y, -depth, 1)
                let world4 = camToWorld * camLocal
                samples[row * cols + col] = SIMD3(world4.x, world4.y, world4.z)
            }
        }

        func appendSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
            let dir = b - a
            let len = simd_length(dir)
            guard len > 0.008, len < 0.45 else { return }
            let tangent = dir / len
            var sideDir = simd_cross(tangent, SIMD3<Float>(0, 1, 0))
            if simd_length_squared(sideDir) < 1e-6 {
                sideDir = simd_cross(tangent, SIMD3<Float>(1, 0, 0))
            }
            guard simd_length_squared(sideDir) >= 1e-6 else { return }
            let side = simd_normalize(sideDir) * depthGridHalfWidth
            let baseIdx = UInt32(result.positions.count)
            result.positions.append(a - side)
            result.positions.append(a + side)
            result.positions.append(b + side)
            result.positions.append(b - side)
            result.indices.append(contentsOf: [
                baseIdx, baseIdx + 1, baseIdx + 2,
                baseIdx, baseIdx + 2, baseIdx + 3
            ])
        }

        for row in 0..<rows {
            for col in 0..<cols {
                guard let p = samples[row * cols + col] else { continue }
                if col + 1 < cols, let q = samples[row * cols + col + 1] {
                    appendSegment(p, q)
                }
                if row + 1 < rows, let q = samples[(row + 1) * cols + col] {
                    appendSegment(p, q)
                }
            }
        }
        return result
    }

    private func makeAnchorEntities(transform: Transform, in root: AnchorEntity) -> AnchorEntities {
        let fill = ModelEntity(
            mesh: .generateBox(size: 0.001),
            materials: [Self.makeFillMaterial()]
        )
        let tentativeLines = ModelEntity(
            mesh: .generateBox(size: 0.001),
            materials: [Self.makeLineMaterial(color: Self.tentativeColor)]
        )
        let stableLines = ModelEntity(
            mesh: .generateBox(size: 0.001),
            materials: [Self.makeLineMaterial(color: Self.stableColor)]
        )
        fill.isEnabled = false
        tentativeLines.isEnabled = false
        stableLines.isEnabled = false
        fill.transform = transform
        tentativeLines.transform = transform
        stableLines.transform = transform
        root.addChild(fill)
        root.addChild(tentativeLines)
        root.addChild(stableLines)
        return AnchorEntities(fill: fill, tentativeLines: tentativeLines, stableLines: stableLines)
    }

    private static func assign(_ mesh: MeshResource?, to entity: ModelEntity) {
        if let mesh {
            entity.model?.mesh = mesh
            entity.isEnabled = true
        } else {
            entity.isEnabled = false
        }
    }

    // MARK: - Materials

    private static func makeLineMaterial(color: UIColor) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.blending = .opaque
        return material
    }

    private static func makeFillMaterial() -> UnlitMaterial {
        var material = UnlitMaterial(color: tentativeColor)
        material.blending = .transparent(opacity: .init(floatLiteral: tentativeFillOpacity))
        return material
    }

    // MARK: - Geometry

    private struct GeometrySnapshot {
        let positions: [SIMD3<Float>]
        let triangles: [UInt32]
    }

    private struct SplitBuffers {
        var fill = GeometryBuffers()
        var tentativeLines = GeometryBuffers()
        var stableLines = GeometryBuffers()
    }

    private struct GeometryBuffers {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var isEmpty: Bool { positions.isEmpty || indices.isEmpty }
    }

    private static func generateMesh(_ buffers: GeometryBuffers, name: String) -> MeshResource? {
        guard !buffers.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "lidar-\(name)")
        descriptor.positions = MeshBuffers.Positions(buffers.positions)
        descriptor.primitives = .triangles(buffers.indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    private static func snapshotGeometry(from anchor: ARMeshAnchor) -> GeometrySnapshot? {
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let faces = geometry.faces
        guard vertices.format == .float3 else { return nil }
        guard faces.primitiveType == .triangle else { return nil }

        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(vertices.count)
        let vBuffer = vertices.buffer.contents()
        for i in 0..<vertices.count {
            let ptr = vBuffer.advanced(by: vertices.offset + vertices.stride * i)
            positions.append(ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee)
        }

        let indexCount = faces.count * faces.indexCountPerPrimitive
        var tri = [UInt32]()
        let faceStep = max(1, faces.count / (maxEdgesPerAnchor / 3 + 1))
        tri.reserveCapacity(min(indexCount, maxEdgesPerAnchor * 3))
        let fBuffer = faces.buffer.contents()
        if faces.bytesPerIndex == MemoryLayout<UInt32>.size {
            let typed = fBuffer.assumingMemoryBound(to: UInt32.self)
            for faceIndex in Swift.stride(from: 0, to: faces.count, by: faceStep) {
                let base = faceIndex * faces.indexCountPerPrimitive
                for j in 0..<faces.indexCountPerPrimitive {
                    tri.append(typed[base + j])
                }
            }
        } else if faces.bytesPerIndex == MemoryLayout<UInt16>.size {
            let typed = fBuffer.assumingMemoryBound(to: UInt16.self)
            for faceIndex in Swift.stride(from: 0, to: faces.count, by: faceStep) {
                let base = faceIndex * faces.indexCountPerPrimitive
                for j in 0..<faces.indexCountPerPrimitive {
                    tri.append(UInt32(typed[base + j]))
                }
            }
        } else {
            return nil
        }
        return GeometrySnapshot(positions: positions, triangles: tri)
    }

    private static func computeFastTentative(
        positions: [SIMD3<Float>],
        triangles: [UInt32],
        worldTransform: simd_float4x4
    ) -> SplitBuffers {
        var result = SplitBuffers()
        let inv = worldTransform.inverse
        let up4 = inv * SIMD4<Float>(0, 1, 0, 0)
        var upLocal = SIMD3<Float>(up4.x, up4.y, up4.z)
        if simd_length_squared(upLocal) < 1e-8 {
            upLocal = SIMD3(0, 1, 0)
        } else {
            upLocal = simd_normalize(upLocal)
        }
        buildRibbon(
            triangles: triangles,
            positions: positions,
            upLocal: upLocal,
            into: &result.tentativeLines
        )
        return result
    }

    private static func computeSplit(
        positions: [SIMD3<Float>],
        triangles: [UInt32],
        worldTransform: simd_float4x4,
        snapshot: ScanCoverageSnapshot
    ) -> SplitBuffers {
        var result = SplitBuffers()
        guard !triangles.isEmpty else { return result }
        let triangleCount = triangles.count / 3

        var stableEdgeTriangles: [UInt32] = []
        var tentativeEdgeTriangles: [UInt32] = []
        stableEdgeTriangles.reserveCapacity(triangles.count)
        tentativeEdgeTriangles.reserveCapacity(triangles.count)

        for t in 0..<triangleCount {
            let i0 = triangles[t * 3]
            let i1 = triangles[t * 3 + 1]
            let i2 = triangles[t * 3 + 2]
            let centroid = (positions[Int(i0)] + positions[Int(i1)] + positions[Int(i2)]) / 3
            let world = worldTransform * SIMD4<Float>(centroid.x, centroid.y, centroid.z, 1)
            let isStable = snapshot.state(worldX: world.x, worldZ: world.z) == .stable
            if isStable {
                stableEdgeTriangles.append(contentsOf: [i0, i1, i2])
            } else {
                tentativeEdgeTriangles.append(contentsOf: [i0, i1, i2])
                if enableFillMesh {
                    let base = UInt32(result.fill.positions.count)
                    result.fill.positions.append(positions[Int(i0)])
                    result.fill.positions.append(positions[Int(i1)])
                    result.fill.positions.append(positions[Int(i2)])
                    result.fill.indices.append(contentsOf: [base, base + 1, base + 2])
                }
            }
        }

        // 월드 위쪽을 메시 로컬로 — 카메라 대향 리본(나디르에서 얇아짐) 대신 수평 펼침
        let inv = worldTransform.inverse
        let up4 = inv * SIMD4<Float>(0, 1, 0, 0)
        var upLocal = SIMD3<Float>(up4.x, up4.y, up4.z)
        if simd_length_squared(upLocal) < 1e-8 {
            upLocal = SIMD3(0, 1, 0)
        } else {
            upLocal = simd_normalize(upLocal)
        }

        buildRibbon(
            triangles: tentativeEdgeTriangles,
            positions: positions,
            upLocal: upLocal,
            into: &result.tentativeLines
        )
        buildRibbon(
            triangles: stableEdgeTriangles,
            positions: positions,
            upLocal: upLocal,
            into: &result.stableLines
        )
        return result
    }

    private static func buildRibbon(
        triangles: [UInt32],
        positions: [SIMD3<Float>],
        upLocal: SIMD3<Float>,
        into buffers: inout GeometryBuffers
    ) {
        guard !triangles.isEmpty else { return }
        let edges = uniqueEdges(from: triangles)
        guard !edges.isEmpty else { return }
        let stride = max(1, edges.count / maxEdgesPerAnchor)
        let halfWidth = ribbonHalfWidth

        var index = 0
        for edge in edges {
            defer { index += 1 }
            if index % stride != 0 { continue }
            let a = positions[Int(edge.0)]
            let b = positions[Int(edge.1)]
            let dir = b - a
            let len = simd_length(dir)
            guard len > 0.01 else { continue }
            let tangent = dir / len
            var sideDirection = simd_cross(tangent, upLocal)
            if simd_length_squared(sideDirection) < 0.0001 {
                sideDirection = simd_cross(tangent, SIMD3<Float>(1, 0, 0))
            }
            guard simd_length_squared(sideDirection) >= 0.0001 else { continue }
            let side = simd_normalize(sideDirection) * halfWidth
            // 바닥 z-fighting 완화: 살짝 띄움
            let lift = upLocal * 0.004
            let base = UInt32(buffers.positions.count)
            buffers.positions.append(a - side + lift)
            buffers.positions.append(a + side + lift)
            buffers.positions.append(b + side + lift)
            buffers.positions.append(b - side + lift)
            buffers.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
    }

    private static func uniqueEdges(from tri: [UInt32]) -> [(UInt32, UInt32)] {
        var set = Set<UInt64>()
        var edges: [(UInt32, UInt32)] = []
        let count = tri.count / 3
        edges.reserveCapacity(count * 2)
        for t in 0..<count {
            let i0 = tri[t * 3]
            let i1 = tri[t * 3 + 1]
            let i2 = tri[t * 3 + 2]
            appendEdge(i0, i1, into: &set, edges: &edges)
            appendEdge(i1, i2, into: &set, edges: &edges)
            appendEdge(i2, i0, into: &set, edges: &edges)
        }
        return edges
    }

    private static func appendEdge(
        _ a: UInt32,
        _ b: UInt32,
        into set: inout Set<UInt64>,
        edges: inout [(UInt32, UInt32)]
    ) {
        let lo = min(a, b)
        let hi = max(a, b)
        let key = (UInt64(lo) << 32) | UInt64(hi)
        guard set.insert(key).inserted else { return }
        edges.append((lo, hi))
    }
}
