import ARKit
import Foundation
import PuttPhysicsKit
import RealityKit
import simd
import UIKit

/// sceneDepth 누적 커버리지 바둑판 표시.
/// ARKit 메시 리본·면 채움은 삼각 폴리곤·추적 흔들림을 만들므로 쓰지 않는다.
/// 물리/앵커에는 주입하지 않는다.
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
    private var coverageFillEntity: ModelEntity?
    private var coverageBlueEntity: ModelEntity?
    private var coverageWhiteEntity: ModelEntity?
    private var lastGlobalRebuildTime: TimeInterval = 0
    private var lastDepthRebuildTime: TimeInterval = 0
    private var lastCoverageRebuildTime: TimeInterval = 0
    private var depthBuilding = false
    private var coverageBuilding = false
    private var coverageRebuildPending = false
    private weak var coverageHostView: ARView?
    private var enabled = false
    private var pipelinePrewarmAnchor: AnchorEntity?
    /// 표시 격자 높이. 매 프레임 중앙값을 쓰면 폰을 움직일 때 면이 떠다닌다.
    private var lockedCoveragePlaneY: Float?
    private var lastCoverageDisplaySignature: Int = 0
    private static let planeLockCellCount = CoverageDisplayLock.minCellsToPlant
    /// 볼 지정 전 바둑판을 빨리 띄우기 위한 표시 전용 임계(물리 minCellsToPlant와 분리).
    private static let quickDisplayCellCount = 2
    /// 칸은 ARAnchor에 고정. 스캔 직후 레이캐스트로 끌면 격자가 흐른다.
    private var coverageStickEntity: AnchorEntity?
    /// 스틱 로컬 격자 원점에 대응하는 월드 5cm 셀 키.
    private var coverageGridAnchorKey: Int64?
    /// 볼 기준으로 심은 스틱이면 재심기 방지.
    private var coverageStickPlantBallXZ: SIMD2<Double>?
    private var frozenWorldKeys: Set<Int64> = []
    private var worldToLocalKey: [Int64: Int64] = [:]
    private var frozenLocalCells: [Int64: DisplaySurfaceGrid.Cell] = [:]
    private var frozenLocalStable: Set<Int64> = []
    private var originSettle = CoverageOriginSettle.quickDisplay
    private var lastIngestCameraXZ: SIMD2<Float>?
    /// 원점 점프 직후 잠깐 새 월드 키만 막는다. 영구 잠금은 보행 중 AR 보정 한 번에 격자가 멈춘다.
    private var newCellIngestSuppressedUntil: TimeInterval = 0
    /// 한 틱에 이보다 크면 걸음이 아니라 원점 보정으로 본다. 0.06s·1.5m/s 보행은 약 9cm.
    private static let ingestOriginJumpMeters: Float = 0.25
    /// 원점 점프 후 새 칸 억제 시간. 짧게 두면 보행 중 격자가 다시 쌓인다.
    private static let ingestJumpSuppressDuration: TimeInterval = 0.35

    /// 워밍업 모드 — 지오메트리는 계속 빌드하되 화면에는 표시하지 않음.
    /// 스캔 시작 시 false로 바꾸면 이미 빌드된 메시가 즉시 나타난다.
    var contentHidden = false {
        didSet {
            guard oldValue != contentHidden else { return }
            applyContentVisibility()
        }
    }

    private func applyContentVisibility() {
        let visible = !contentHidden
        rootAnchor?.isEnabled = visible
        coverageStickEntity?.isEnabled = visible
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
    /// 홀이 지정되면 복도 밖 커버리지 격자를 숨긴다.
    var corridorBallXZ: SIMD2<Double>?
    var corridorBallY: Float?
    var corridorHoleXZ: SIMD2<Double>?
    var corridorPastHoleMeters: Double = PuttScanCorridor.pastHoleMargin
    var corridorHalfWidthMeters: Double = PuttScanCorridor.orthogonalHalfWidth

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
            // 세션 identity ARAnchor는 트래킹 보정 때 흔들린다.
            // RealityKit 월드 고정 — 격자 정점은 ARKit 월드 좌표 그대로 둔다.
            let root = AnchorEntity(.world(transform: matrix_identity_float4x4))
            root.name = "trueputt.viz-origin"
            applyContentVisibility()
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
        detachCoverageStick(in: view)
        entities.removeAll()
        missingMeshFrames.removeAll()
        depthGridEntity = nil
        enabled = false
        coverageSnapshot = .empty
        depthBuilding = false
        coverageBuilding = false
        coverageRebuildPending = false
        coverageHostView = nil
        coverageFillEntity = nil
        coverageBlueEntity = nil
        coverageWhiteEntity = nil
        corridorBallXZ = nil
        corridorBallY = nil
        corridorHoleXZ = nil
        lockedCoveragePlaneY = nil
        lastCoverageDisplaySignature = 0
        coverageStickPlantBallXZ = nil
        lastIngestCameraXZ = nil
        newCellIngestSuppressedUntil = 0
        clearFrozenCoverageCells()
    }

    private func clearFrozenCoverageCells() {
        frozenWorldKeys.removeAll(keepingCapacity: true)
        worldToLocalKey.removeAll(keepingCapacity: true)
        frozenLocalCells.removeAll(keepingCapacity: true)
        frozenLocalStable.removeAll(keepingCapacity: true)
    }

    /// 스캔 시작 때 호출. 이전 워밍업 높이로 바둑판이 미끄러지지 않게 한다.
    func resetCoverageDisplayLock(in view: ARView? = nil) {
        lockedCoveragePlaneY = nil
        lastCoverageDisplaySignature = 0
        coverageStickPlantBallXZ = nil
        lastIngestCameraXZ = nil
        newCellIngestSuppressedUntil = 0
        originSettle = CoverageOriginSettle.quickDisplay
        clearFrozenCoverageCells()
        if let view {
            detachCoverageStick(in: view)
        }
    }

    func update(in view: ARView) {
        guard enabled, rootAnchor != nil else { return }
        guard let frame = view.session.currentFrame else { return }
        let now = frame.timestamp

        // 표시는 5cm 커버리지 바둑판만 사용. ARKit 메시 리본은 삼각형·추적 흔들림이 보여
        // “가끔 파란 폴리곤 / 흰 격자 흐름”으로 보인다 — 만들지 않고 잔여분도 즉시 제거.
        clearARKitRibbonEntities()

        // sceneDepth 누적 커버리지 격자
        updateCoverageGrid(now: now, in: view)

        // 매 프레임 depth 격자는 현재 화면만 보여 폰을 따라 흐른다. 쓰지 않는다.
        depthGridEntity?.isEnabled = false
        _ = frame
    }

    private func clearARKitRibbonEntities() {
        guard !entities.isEmpty else {
            missingMeshFrames.removeAll(keepingCapacity: true)
            return
        }
        for (_, entity) in entities {
            entity.fill.removeFromParent()
            entity.tentativeLines.removeFromParent()
            entity.stableLines.removeFromParent()
        }
        entities.removeAll(keepingCapacity: true)
        missingMeshFrames.removeAll(keepingCapacity: true)
    }

    // MARK: - Coverage grid (5cm, ARKit 메시와 독립)

    /// 표시 격자는 5cm 키의 정규 중심에 맞춘다. lastX/lastZ 평균은 칸 안 샘플 편향으로 앵커가 옆으로 밀릴 수 있다.
    private static func coverageGridCenters(from snapshot: ScanCoverageSnapshot) -> [SIMD2<Float>] {
        snapshot.cellCenters.keys.map { CoverageDisplayLock.cellCenterXZ($0) }
    }

    private func updateCoverageGrid(now: TimeInterval, in view: ARView) {
        coverageFillEntity?.transform = Transform()
        coverageBlueEntity?.transform = Transform()
        coverageWhiteEntity?.transform = Transform()
        guard !contentHidden else {
            coverageFillEntity?.isEnabled = false
            coverageBlueEntity?.isEnabled = false
            coverageWhiteEntity?.isEnabled = false
            return
        }
        let snapshot = coverageSnapshot
        if snapshot.observedCellCount == 0, frozenLocalCells.isEmpty {
            coverageFillEntity?.isEnabled = false
            coverageBlueEntity?.isEnabled = false
            coverageWhiteEntity?.isEnabled = false
            return
        }

        let ball = corridorBallXZ
        let hole = corridorHoleXZ
        let past = corridorPastHoleMeters
        let half = corridorHalfWidthMeters
        let planeY = lockedDisplayPlaneY(from: snapshot, ballY: corridorBallY)
        guard lockedCoveragePlaneY != nil else {
            coverageFillEntity?.isEnabled = false
            coverageBlueEntity?.isEnabled = false
            coverageWhiteEntity?.isEnabled = false
            return
        }

        if !ensureCoverageStickPlanted(
            planeY: planeY,
            snapshot: snapshot,
            ball: ball,
            now: now,
            in: view
        ) {
            coverageFillEntity?.isEnabled = false
            coverageBlueEntity?.isEnabled = false
            coverageWhiteEntity?.isEnabled = false
            return
        }
        guard let stick = coverageStickEntity else { return }

        if snapshot.observedCellCount > 0 {
            let gate = coverageIngestGate(in: view, now: now)
            if !gate.skip {
                ingestFrozenCells(
                    snapshot: snapshot,
                    ball: ball,
                    hole: hole,
                    pastHole: past,
                    halfWidth: half,
                    planeY: planeY,
                    allowNewCells: gate.allowNewCells
                )
            }
        }
        rebuildCoverageMeshIfNeeded(
            now: now,
            in: view,
            snapshot: snapshot,
            stick: stick,
            ball: ball,
            hole: hole,
            pastHole: past,
            halfWidth: half
        )
    }

    private func currentCoverageDisplaySignature(
        ball: SIMD2<Double>?,
        hole: SIMD2<Double>?,
        pastHole: Double,
        halfWidth: Double
    ) -> Int {
        let localCells = visibleLocalCells(
            ball: ball,
            hole: hole,
            pastHole: pastHole,
            halfWidth: halfWidth
        )
        return frozenDisplaySignature(visibleCount: localCells.count)
    }

    private func rebuildCoverageMeshIfNeeded(
        now: TimeInterval,
        in view: ARView,
        snapshot: ScanCoverageSnapshot,
        stick: AnchorEntity,
        ball: SIMD2<Double>?,
        hole: SIMD2<Double>?,
        pastHole: Double,
        halfWidth: Double
    ) {
        coverageHostView = view
        let signature = currentCoverageDisplaySignature(
            ball: ball,
            hole: hole,
            pastHole: pastHole,
            halfWidth: halfWidth
        )
        guard signature != lastCoverageDisplaySignature else {
            coverageRebuildPending = false
            return
        }
        if coverageBuilding {
            coverageRebuildPending = true
            return
        }

        coverageRebuildPending = false
        lastCoverageRebuildTime = now
        coverageBuilding = true
        ensureCoverageEntities(on: stick)

        let localCells = visibleLocalCells(
            ball: ball,
            hole: hole,
            pastHole: pastHole,
            halfWidth: halfWidth
        )
        let localSnapshot = localCoverageSnapshot(from: snapshot, cells: localCells)
        let buildSignature = signature
        buildQueue.async { [weak self] in
            let split = DisplaySurfaceGrid.buildSplitMeshes(
                cells: localCells,
                coverage: localSnapshot,
                cellSize: DisplaySurfaceGrid.cellSizeMeters,
                lineHalfWidth: 0.001
            )
            let blueMesh = Self.generateMesh(
                GeometryBuffers(positions: split.tentativeLines.positions, indices: split.tentativeLines.indices),
                name: "cov-blue"
            )
            let whiteMesh = Self.generateMesh(
                GeometryBuffers(positions: split.stableLines.positions, indices: split.stableLines.indices),
                name: "cov-white"
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.coverageBuilding = false
                let latestSignature = self.currentCoverageDisplaySignature(
                    ball: ball,
                    hole: hole,
                    pastHole: pastHole,
                    halfWidth: halfWidth
                )
                guard buildSignature == latestSignature else {
                    if let host = self.coverageHostView {
                        self.rebuildCoverageMeshIfNeeded(
                            now: now,
                            in: host,
                            snapshot: self.coverageSnapshot,
                            stick: stick,
                            ball: ball,
                            hole: hole,
                            pastHole: pastHole,
                            halfWidth: halfWidth
                        )
                    } else {
                        self.coverageRebuildPending = true
                    }
                    return
                }
                if let fill = self.coverageFillEntity {
                    fill.isEnabled = false
                }
                if let blue = self.coverageBlueEntity { self.assignCoverageMesh(blueMesh, to: blue) }
                if let white = self.coverageWhiteEntity { self.assignCoverageMesh(whiteMesh, to: white) }
                self.lastCoverageDisplaySignature = buildSignature
                let afterSignature = self.currentCoverageDisplaySignature(
                    ball: ball,
                    hole: hole,
                    pastHole: pastHole,
                    halfWidth: halfWidth
                )
                if afterSignature != buildSignature, let host = self.coverageHostView {
                    self.rebuildCoverageMeshIfNeeded(
                        now: now,
                        in: host,
                        snapshot: self.coverageSnapshot,
                        stick: stick,
                        ball: ball,
                        hole: hole,
                        pastHole: pastHole,
                        halfWidth: halfWidth
                    )
                }
            }
        }
    }

    private func ingestFrozenCells(
        snapshot: ScanCoverageSnapshot,
        ball: SIMD2<Double>?,
        hole: SIMD2<Double>?,
        pastHole: Double,
        halfWidth: Double,
        planeY: Float,
        allowNewCells: Bool
    ) {
        guard let anchorKey = coverageGridAnchorKey else { return }
        let lift: Float = 0.004
        for (key, _) in snapshot.cellHeights {
            let center = CoverageDisplayLock.cellCenterXZ(key)
            if let ball, let hole {
                guard Self.isInsideDisplayCorridor(
                    x: Double(center.x),
                    z: Double(center.y),
                    ball: ball,
                    hole: hole,
                    halfWidth: halfWidth,
                    pastHole: pastHole
                ) else { continue }
            }
            let isStable = snapshot.stableKeys.contains(key)
            if let localKey = worldToLocalKey[key] {
                if isStable {
                    frozenLocalStable.insert(localKey)
                }
                continue
            }
            guard allowNewCells else { continue }
            let resolved = CoverageDisplayLock.localCell(
                worldKey: key,
                anchorKey: anchorKey,
                lift: lift,
                existing: frozenLocalCells
            )
            frozenWorldKeys.insert(key)
            worldToLocalKey[key] = resolved.key
            if resolved.created {
                frozenLocalCells[resolved.key] = resolved.cell
            }
            if isStable {
                frozenLocalStable.insert(resolved.key)
            }
        }
    }

    private func rekeyFrozenCoverageCells(to newAnchorKey: Int64) {
        guard let oldAnchorKey = coverageGridAnchorKey, oldAnchorKey != newAnchorKey else { return }
        var newWorldToLocal: [Int64: Int64] = [:]
        var newFrozenLocal: [Int64: DisplaySurfaceGrid.Cell] = [:]
        var newFrozenStable: Set<Int64> = []
        for worldKey in frozenWorldKeys {
            let newLocalKey = CoverageDisplayLock.localCellKey(worldKey: worldKey, anchorKey: newAnchorKey)
            let oldLocalKey = worldToLocalKey[worldKey]
            let height = oldLocalKey.flatMap { frozenLocalCells[$0]?.height } ?? 0
            let (lix, liz) = CoverageDisplayLock.unpack(newLocalKey)
            newFrozenLocal[newLocalKey] = DisplaySurfaceGrid.Cell(ix: lix, iz: liz, height: height)
            newWorldToLocal[worldKey] = newLocalKey
            if let oldLocalKey, frozenLocalStable.contains(oldLocalKey) {
                newFrozenStable.insert(newLocalKey)
            }
        }
        worldToLocalKey = newWorldToLocal
        frozenLocalCells = newFrozenLocal
        frozenLocalStable = newFrozenStable
        coverageGridAnchorKey = newAnchorKey
        lastCoverageDisplaySignature = 0
    }

    private func ensureCoverageStickPlanted(
        planeY: Float,
        snapshot: ScanCoverageSnapshot,
        ball: SIMD2<Double>?,
        now: TimeInterval,
        in view: ARView
    ) -> Bool {
        if coverageStickEntity != nil {
            if let ball {
                coverageStickPlantBallXZ = ball
            }
            return true
        }

        let preBallPlacement = ball == nil && coverageStickPlantBallXZ == nil
        let minCells = preBallPlacement ? Self.quickDisplayCellCount : Self.planeLockCellCount
        let readyCount = snapshot.observedCellCount >= minCells
            || (!frozenLocalCells.isEmpty && snapshot.observedCellCount > 0)
        guard readyCount else { return false }
        let centers = Self.coverageGridCenters(from: snapshot)
        let centroid = CoverageDisplayLock.centroidXZ(of: centers)
        guard let anchorKey = Self.coverageAnchorKey(from: snapshot) else { return false }
        if preBallPlacement {
            attachCoverageStick(planeY: planeY, anchorKey: anchorKey, in: view)
            return true
        }
        guard originSettle.observe(centroid, now: now) else { return false }
        attachCoverageStick(planeY: planeY, anchorKey: anchorKey, in: view)
        if let ball {
            coverageStickPlantBallXZ = ball
        }
        return true
    }

    /// AR 원점 점프 직후에만 새 칸을 잠깐 막는다. 서 있어도 LiDAR 스냅샷으로 구멍을 메운다.
    private func coverageIngestGate(in view: ARView, now: TimeInterval) -> (allowNewCells: Bool, skip: Bool) {
        guard let frame = view.session.currentFrame else { return (false, true) }
        let cam = frame.camera.transform.columns.3
        let xz = SIMD2<Float>(cam.x, cam.z)
        defer { lastIngestCameraXZ = xz }

        let suppressionActive = now < newCellIngestSuppressedUntil
        if case .limited = frame.camera.trackingState {
            return (false, false)
        }
        guard let previous = lastIngestCameraXZ else { return (true, false) }
        let moved = simd_distance(previous, xz)
        if moved >= Self.ingestOriginJumpMeters {
            newCellIngestSuppressedUntil = now + Self.ingestJumpSuppressDuration
            return (false, false)
        }
        return (!suppressionActive, false)
    }

    private static func coverageAnchorKey(forBall ball: SIMD2<Double>) -> Int64 {
        CoverageDisplayLock.gridAnchorKey(
            for: SIMD2(Float(ball.x), Float(ball.y))
        )
    }

    private static func coverageAnchorKey(from snapshot: ScanCoverageSnapshot) -> Int64? {
        guard let centroid = CoverageDisplayLock.centroidXZ(
            of: coverageGridCenters(from: snapshot)
        ) else { return nil }
        return CoverageDisplayLock.gridAnchorKey(for: centroid)
    }

    private func attachCoverageStick(
        planeY: Float,
        anchorKey: Int64,
        in view: ARView
    ) {
        guard coverageStickEntity == nil else { return }
        let (anchorIX, anchorIZ) = CoverageDisplayLock.unpack(anchorKey)
        let cellSize = CoverageDisplayLock.cellSizeMeters
        coverageGridAnchorKey = anchorKey

        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(
            Float(anchorIX) * cellSize,
            planeY,
            Float(anchorIZ) * cellSize,
            1
        )

        // ARAnchor는 트래킹 보정 때 위치가 갱신되어 격자가 흐른다. 월드 고정만 사용.
        let stick = AnchorEntity(.world(transform: transform))
        stick.name = "trueputt.coverage-stick"
        stick.isEnabled = !contentHidden
        view.scene.addAnchor(stick)
        coverageStickEntity = stick
    }

    private func assignCoverageMesh(_ mesh: MeshResource?, to entity: ModelEntity) {
        if let mesh {
            entity.model?.mesh = mesh
            entity.isEnabled = !contentHidden
        } else {
            entity.isEnabled = false
        }
    }

    private func detachCoverageStick(in view: ARView) {
        if let stick = coverageStickEntity {
            view.scene.removeAnchor(stick)
        }
        coverageStickEntity = nil
        coverageGridAnchorKey = nil
        coverageStickPlantBallXZ = nil
        coverageFillEntity?.removeFromParent()
        coverageBlueEntity?.removeFromParent()
        coverageWhiteEntity?.removeFromParent()
        coverageFillEntity = nil
        coverageBlueEntity = nil
        coverageWhiteEntity = nil
    }

    private func ensureCoverageEntities(on parent: Entity) {
        if coverageFillEntity == nil {
            let fill = ModelEntity(
                mesh: .generateBox(size: 0.001),
                materials: [Self.makeFillMaterial()]
            )
            let blue = ModelEntity(
                mesh: .generateBox(size: 0.001),
                materials: [Self.makeLineMaterial(color: Self.tentativeColor)]
            )
            let white = ModelEntity(
                mesh: .generateBox(size: 0.001),
                materials: [Self.makeLineMaterial(color: Self.stableColor)]
            )
            fill.isEnabled = false
            blue.isEnabled = false
            white.isEnabled = false
            coverageFillEntity = fill
            coverageBlueEntity = blue
            coverageWhiteEntity = white
        }
        if let fill = coverageFillEntity, fill.parent !== parent {
            fill.removeFromParent()
            parent.addChild(fill)
        }
        if let blue = coverageBlueEntity, blue.parent !== parent {
            blue.removeFromParent()
            parent.addChild(blue)
        }
        if let white = coverageWhiteEntity, white.parent !== parent {
            white.removeFromParent()
            parent.addChild(white)
        }
    }

    private func visibleLocalCells(
        ball: SIMD2<Double>?,
        hole: SIMD2<Double>?,
        pastHole: Double,
        halfWidth: Double
    ) -> [DisplaySurfaceGrid.Cell] {
        guard let ball, let hole else {
            return Array(frozenLocalCells.values)
        }
        var allowed = Set<Int64>()
        allowed.reserveCapacity(worldToLocalKey.count)
        for (worldKey, localKey) in worldToLocalKey {
            let center = CoverageDisplayLock.cellCenterXZ(worldKey)
            if Self.isInsideDisplayCorridor(
                x: Double(center.x),
                z: Double(center.y),
                ball: ball,
                hole: hole,
                halfWidth: halfWidth,
                pastHole: pastHole
            ) {
                allowed.insert(localKey)
            }
        }
        return frozenLocalCells.values.filter { allowed.contains($0.key) }
    }

    private func frozenDisplaySignature(visibleCount: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(visibleCount)
        hasher.combine(frozenLocalCells.count)
        hasher.combine(frozenLocalStable.count)
        return hasher.finalize()
    }

    private func localCoverageSnapshot(
        from snapshot: ScanCoverageSnapshot,
        cells: [DisplaySurfaceGrid.Cell]
    ) -> ScanCoverageSnapshot {
        var heights: [Int64: Float] = [:]
        var centers: [Int64: SIMD2<Float>] = [:]
        let cellSize = DisplaySurfaceGrid.cellSizeMeters
        heights.reserveCapacity(cells.count)
        centers.reserveCapacity(cells.count)
        var keys = Set<Int64>()
        keys.reserveCapacity(cells.count)
        for cell in cells {
            heights[cell.key] = cell.height
            centers[cell.key] = SIMD2((Float(cell.ix) + 0.5) * cellSize, (Float(cell.iz) + 0.5) * cellSize)
            keys.insert(cell.key)
        }
        let stable = frozenLocalStable.intersection(keys)
        var local = snapshot
        local.observedCellCount = cells.count
        local.stableCellCount = stable.count
        local.tentativeCellCount = max(0, cells.count - stable.count)
        local.newlyStabilizedCount = 0
        local.stableKeys = stable
        local.tentativeKeys = keys.subtracting(stable)
        local.cellHeights = heights
        local.cellCenters = centers
        return local
    }

    private func lockedDisplayPlaneY(from snapshot: ScanCoverageSnapshot, ballY: Float?) -> Float {
        let heights = Array(snapshot.cellHeights.values)
        let median = Self.medianFloat(heights) ?? 0
        let minCellsForPlane = corridorBallXZ == nil
            ? Self.quickDisplayCellCount
            : Self.planeLockCellCount
        if lockedCoveragePlaneY == nil {
            if let ballY {
                lockedCoveragePlaneY = ballY
            } else if snapshot.observedCellCount >= minCellsForPlane {
                lockedCoveragePlaneY = median
            }
            return lockedCoveragePlaneY ?? ballY ?? median
        }
        return lockedCoveragePlaneY ?? ballY ?? median
    }

    private static func coverageDisplaySignature(
        snapshot: ScanCoverageSnapshot,
        planeY: Float,
        hasCorridor: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.stableKeys)
        hasher.combine(snapshot.tentativeKeys)
        hasher.combine(planeY.bitPattern)
        hasher.combine(hasCorridor)
        return hasher.finalize()
    }

    private static func medianFloat(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }

    private static func coverageDisplayCells(
        snapshot: ScanCoverageSnapshot,
        ball: SIMD2<Double>?,
        hole: SIMD2<Double>?,
        pastHole: Double,
        halfWidth: Double,
        planeY: Float
    ) -> [DisplaySurfaceGrid.Cell] {
        let cellSize = DisplaySurfaceGrid.cellSizeMeters
        var cells: [DisplaySurfaceGrid.Cell] = []
        cells.reserveCapacity(min(snapshot.cellHeights.count, DisplaySurfaceGrid.maxCells))
        for (key, height) in snapshot.cellHeights {
            if cells.count >= DisplaySurfaceGrid.maxCells { break }
            let ix = Int32(truncatingIfNeeded: key >> 32)
            let iz = Int32(bitPattern: UInt32(truncatingIfNeeded: key))
            let x = (Double(ix) + 0.5) * Double(cellSize)
            let z = (Double(iz) + 0.5) * Double(cellSize)
            if let ball, let hole {
                guard isInsideDisplayCorridor(
                    x: x,
                    z: z,
                    ball: ball,
                    hole: hole,
                    halfWidth: halfWidth,
                    pastHole: pastHole
                ) else { continue }
            }
            cells.append(
                DisplaySurfaceGrid.Cell(ix: ix, iz: iz, height: height)
            )
        }
        return DisplaySurfaceGrid.flattenToMedianHeight(cells, lift: 0.004, height: planeY)
    }

    private static func isInsideDisplayCorridor(
        x: Double,
        z: Double,
        ball: SIMD2<Double>,
        hole: SIMD2<Double>,
        halfWidth: Double,
        pastHole: Double
    ) -> Bool {
        let dx = hole.x - ball.x
        let dz = hole.y - ball.y
        let length = hypot(dx, dz)
        guard length > 1e-6 else {
            return hypot(x - ball.x, z - ball.y) <= halfWidth + pastHole
        }
        let ux = dx / length
        let uz = dz / length
        let px = x - ball.x
        let pz = z - ball.y
        let along = px * ux + pz * uz
        let lateral = abs(px * (-uz) + pz * ux)
        return along >= -0.5 && along <= length + pastHole && lateral <= halfWidth
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
