import ARKit
import Foundation
import PuttPhysicsKit
import RealityKit
import simd

/// ARKit 원본 삼각 메시를 그대로 표시(수직 벽면 포함).
/// 끊김·진동 방지: 프레임마다 transform만 갱신하고, 무거운 지오메트리 재생성은
/// 앵커당 스로틀 + 프레임당 1개(라운드로빈) + 백그라운드에서 처리한다.
/// 미확정=파란 선(100%)+파란 면(50%), 안정=흰 선. 물리/앵커에는 주입하지 않는다.
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
    private var rebuildCursor = 0
    private var lastGlobalRebuildTime: TimeInterval = 0
    private var enabled = false

    private static let tentativeColor = UIColor.systemBlue
    private static let tentativeFillOpacity: Float = 0.5
    private static let stableColor = UIColor.white
    /// 앵커별 재생성 최소 간격. 프레임당 1개만 처리해 히칭을 분산.
    private static let perAnchorRebuildInterval: TimeInterval = 2.2
    /// 전체 재생성 최소 간격. SwiftUI 리렌더와 분리된 DisplayLink에서도 충분.
    private static let globalRebuildInterval: TimeInterval = 0.5
    private static let maxEdgesPerAnchor = 8_000
    /// 면 채움은 GPU·빌드 비용이 커서 끄고 선만 그린다(커버리지 피드백은 선 색으로 충분).
    private static let enableFillMesh = false
    /// 너무 큰 메시 앵커 면 다운샘플 기준.
    private static let maxSourceVerticesPerAnchor = 12_000

    private let buildQueue = DispatchQueue(label: "trueputt.mesh-build", qos: .utility)

    var lineWidthPixels: Float = 2
    var coverageSnapshot: ScanCoverageSnapshot = .empty

    func setEnabled(_ on: Bool, in view: ARView) {
        guard on != enabled else { return }
        enabled = on
        if on {
            let root = AnchorEntity(world: .zero)
            view.scene.addAnchor(root)
            rootAnchor = root
        } else {
            teardown(in: view)
        }
    }

    func teardown(in view: ARView) {
        if let rootAnchor {
            view.scene.removeAnchor(rootAnchor)
        }
        rootAnchor = nil
        entities.removeAll()
        rebuildCursor = 0
        enabled = false
        coverageSnapshot = .empty
    }

    func update(in view: ARView) {
        guard enabled, let rootAnchor else { return }
        guard let frame = view.session.currentFrame else { return }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let now = frame.timestamp

        // 1) 매 프레임: transform만 갱신 → 지오메트리가 조금 낡아도 부드럽게 따라감.
        var liveIDs = Set<UUID>()
        for anchor in meshAnchors {
            liveIDs.insert(anchor.identifier)
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
        for (id, entity) in entities where !liveIDs.contains(id) {
            entity.fill.removeFromParent()
            entity.tentativeLines.removeFromParent()
            entity.stableLines.removeFromParent()
            entities.removeValue(forKey: id)
        }

        // 2) 프레임당 1개 앵커만 백그라운드 재생성 (히칭 분산).
        guard !meshAnchors.isEmpty else { return }
        guard now - lastGlobalRebuildTime >= Self.globalRebuildInterval else { return }
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let projection = frame.camera.projectionMatrix(
            for: orientation,
            viewportSize: view.bounds.size,
            zNear: 0.01,
            zFar: 100
        )
        let projectionYScale = max(abs(projection[1][1]), 0.001)
        let viewportPixelHeight = max(Float(view.bounds.height * view.contentScaleFactor), 1)
        let targetPixelWidth = max(lineWidthPixels, 1)
        let cameraWorld = frame.camera.transform
        let snapshot = coverageSnapshot

        let count = meshAnchors.count
        for offset in 0..<count {
            let index = (rebuildCursor + offset) % count
            let anchor = meshAnchors[index]
            guard let entity = entities[anchor.identifier] else { continue }
            guard !entity.building, now - entity.lastRebuild >= Self.perAnchorRebuildInterval else { continue }

            entity.building = true
            entity.lastRebuild = now
            lastGlobalRebuildTime = now
            rebuildCursor = (index + 1) % count

            // 무거운 버퍼 스냅샷은 메인에서 1개만.
            guard let snapshotGeo = Self.snapshotGeometry(from: anchor) else {
                entity.building = false
                break
            }
            let cameraLocal = anchor.transform.inverse * cameraWorld
            let cameraLocalPos = SIMD3<Float>(
                cameraLocal.columns.3.x,
                cameraLocal.columns.3.y,
                cameraLocal.columns.3.z
            )
            let worldTransform = anchor.transform

            buildQueue.async { [weak entity] in
                let split = Self.computeSplit(
                    positions: snapshotGeo.positions,
                    triangles: snapshotGeo.triangles,
                    worldTransform: worldTransform,
                    cameraLocalPosition: cameraLocalPos,
                    targetPixelWidth: targetPixelWidth,
                    projectionYScale: projectionYScale,
                    viewportPixelHeight: viewportPixelHeight,
                    snapshot: snapshot
                )
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
            break // 프레임당 1개만
        }
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

        // 초대형 앵커는 면만 다운샘플 — 선 프리뷰 부하 완화
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

    private static func computeSplit(
        positions: [SIMD3<Float>],
        triangles: [UInt32],
        worldTransform: simd_float4x4,
        cameraLocalPosition: SIMD3<Float>,
        targetPixelWidth: Float,
        projectionYScale: Float,
        viewportPixelHeight: Float,
        snapshot: ScanCoverageSnapshot
    ) -> SplitBuffers {
        var result = SplitBuffers()
        guard !triangles.isEmpty else { return result }
        let triangleCount = triangles.count / 3

        // 삼각형 상태 분류 + 미확정 면 채움.
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

        buildRibbon(
            triangles: tentativeEdgeTriangles,
            positions: positions,
            cameraLocalPosition: cameraLocalPosition,
            targetPixelWidth: targetPixelWidth,
            projectionYScale: projectionYScale,
            viewportPixelHeight: viewportPixelHeight,
            into: &result.tentativeLines
        )
        buildRibbon(
            triangles: stableEdgeTriangles,
            positions: positions,
            cameraLocalPosition: cameraLocalPosition,
            targetPixelWidth: targetPixelWidth,
            projectionYScale: projectionYScale,
            viewportPixelHeight: viewportPixelHeight,
            into: &result.stableLines
        )
        return result
    }

    private static func buildRibbon(
        triangles: [UInt32],
        positions: [SIMD3<Float>],
        cameraLocalPosition: SIMD3<Float>,
        targetPixelWidth: Float,
        projectionYScale: Float,
        viewportPixelHeight: Float,
        into buffers: inout GeometryBuffers
    ) {
        guard !triangles.isEmpty else { return }
        let edges = uniqueEdges(from: triangles)
        guard !edges.isEmpty else { return }
        let stride = max(1, edges.count / maxEdgesPerAnchor)

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
            let midpoint = (a + b) * 0.5
            let toCamera = cameraLocalPosition - midpoint
            let distance = max(simd_length(toCamera), 0.05)
            var sideDirection = simd_cross(tangent, simd_normalize(toCamera))
            if simd_length_squared(sideDirection) < 0.0001 {
                sideDirection = simd_cross(tangent, SIMD3<Float>(0, 1, 0))
            }
            guard simd_length_squared(sideDirection) >= 0.0001 else { continue }
            let metersPerPixel = (2 * distance) / (projectionYScale * viewportPixelHeight)
            let halfWidth = targetPixelWidth * metersPerPixel * 0.5
            let side = simd_normalize(sideDirection) * halfWidth
            let base = UInt32(buffers.positions.count)
            buffers.positions.append(a - side)
            buffers.positions.append(a + side)
            buffers.positions.append(b + side)
            buffers.positions.append(b - side)
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
