import ARKit
import Combine
import Foundation
import PuttPhysicsKit
import RealityKit
import UIKit

enum ScanFlowState: Equatable {
    case idle
    case preparing
    case placingBall
    case walkingToHole
    case placingHole
    case returningToBall
    case processing
    case complete
    case failed(String)
}

/// 스캔 경로. 기본은 왕복(볼 복귀·드리프트 보정). 편도는 홀에서 즉시 계산.
enum ScanPathMode: String, CaseIterable, Identifiable {
    case oneWay
    case roundTrip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneWay: return "편도"
        case .roundTrip: return "왕복(기본)"
        }
    }

    var detail: String {
        switch self {
        case .oneWay:
            return "홀까지 한 번만. 드리프트 보정 없음(간편)."
        case .roundTrip:
            return "홀 지정 후 볼로 돌아와 종료. 볼 재지정 없음 · 드리프트 보정."
        }
    }
}

enum PlacementKind: Equatable {
    case ball
    case hole
    case reanchorHole
}

struct TrackingEvent: Codable, Equatable {
    let timestamp: TimeInterval
    let state: String
    let isLimited: Bool
}

struct CompletedScan {
    let id: String
    let result: TerrainPipelineResult
    let trackingEvents: [TrackingEvent]
    let limitedTrackingRatio: Double
    let startedAt: Date
    /// 볼 지면 기준점 (AR raycast). 좌표계 원점.
    let ballAnchor: ScanPose
    /// 홀컵 지면 기준점 (AR raycast).
    let holeAnchor: ScanPose
    /// 드리프트용 카메라 시작/복귀 pose (지면 앵커와 분리).
    let cameraStartPose: ScanPose
    let cameraReturnPose: ScanPose
    let holeDistance: Double
    let scanTransform: ScanCoordinateTransform
    let referenceMethod: String
    let ballPlacementTrackingOK: Bool
    let holePlacementTrackingOK: Bool
    /// 왕복이면 true. 편도면 false(드리프트 0으로 처리).
    let driftCorrected: Bool
    let pathMode: ScanPathMode
    /// `temporal_scene_depth` 또는 관측 부족 시 `arkit_mesh_fallback`.
    let surfaceSource: String
    let surfaceVertexCount: Int

    /// Gate55Validation 호환 — 지면 볼 앵커.
    var startPose: ScanPose { ballAnchor }
    /// Gate55Validation 호환 — 지면 홀 앵커.
    var holePose: ScanPose { holeAnchor }
    var returnPose: ScanPose { cameraReturnPose }
}

final class ARScanSessionController: NSObject, ObservableObject {
    static let referenceMethod = "ar_raycast"
    static let minimumHoleDistance = 0.05

    let session = ARSession()

    @Published private(set) var flowState: ScanFlowState = .idle
    @Published private(set) var trackingDescription = "대기 중"
    @Published private(set) var trackingLimited = false
    @Published private(set) var meshVertexCount = 0
    @Published private(set) var completedScan: CompletedScan?
    @Published private(set) var guidanceTrackingEvents: [TrackingEvent] = []
    @Published private(set) var guidanceTrackingOK = true
    @Published private(set) var ballAnchor: ScanPose?
    @Published private(set) var holeAnchor: ScanPose?
    @Published private(set) var placementMessage: String?
    /// AR 뷰가 화면 중앙 raycast를 수행하도록 요청한다.
    @Published var placementRequest: PlacementKind?
    @Published var sigma = 1.5
    /// 기본 편도. 왕복은 홀 지정 후 볼로 돌아와 드리프트 보정.
    @Published var pathMode: ScanPathMode = .roundTrip {
        didSet {
            if gate1RetestLockRoundTrip, pathMode != .roundTrip {
                pathMode = .roundTrip
            }
        }
    }
    /// 게이트1 전체 스택 재측정용 — 켜면 왕복만 허용.
    @Published var gate1RetestLockRoundTrip = false {
        didSet {
            if gate1RetestLockRoundTrip {
                pathMode = .roundTrip
            }
        }
    }
    /// Polycam형 커버리지 스냅샷 (시각·안내용). 물리/앵커에 주입하지 않음.
    @Published private(set) var coverageSnapshot: ScanCoverageSnapshot = .empty
    @Published private(set) var coverageQualityMessage = ScanCoverageQuality.normal.message
    /// 메시 색칠용 최신 스냅샷(@Published 아님 — UI 리렌더와 분리).
    private(set) var meshCoverageSnapshot: ScanCoverageSnapshot = .empty
    private var lastPublishedCoverageRatio: Double = -1
    private var lastMeshVertexPublishTime: TimeInterval = 0
    private var pendingMeshVertexCount = 0
    private var lastMeshCaptureTime: TimeInterval = 0

    private var cameraStartPose: ScanPose?
    private var cameraReturnPose: ScanPose?
    private var ballPlacementTrackingOK = true
    private var holePlacementTrackingOK = true
    private var latestMeshes: [UUID: [ScanVertex]] = [:]
    private var trackingEvents: [TrackingEvent] = []
    private var startedAt = Date()
    private var meshCaptureEnabled = true
    private var guidancePhaseActive = false
    private let coverageTracker = ScanCoverageTracker()
    private var lastCoverageHapticStableCount = 0
    private let coverageHaptic = UIImpactFeedbackGenerator(style: .light)
    /// ARMeshAnchor 정점 복사·필터 전용 직렬 큐 — 메인에서 하면 버튼 탭·스캔 중 히칭.
    private let meshExtractionQueue = DispatchQueue(label: "trueputt.mesh-extract", qos: .userInitiated)

    var currentHoleDistance: Double? {
        guard let ball = ballAnchor, let hole = holeAnchor else { return nil }
        return hypot(hole.worldX - ball.worldX, hole.worldZ - ball.worldZ)
    }

    /// 볼 지정 전에 LiDAR 메시가 충분히 형성됐는지. 최소 정점 수 기준.
    static let meshReadyVertexThreshold = 400

    /// 볼 기준점을 지정해도 될 만큼 메시가 준비됐는지.
    var meshReady: Bool {
#if targetEnvironment(simulator)
        return true
#else
        return meshVertexCount >= Self.meshReadyVertexThreshold
#endif
    }

    override init() {
        super.init()
        session.delegate = self
        // 앱 시작 즉시 카메라·LiDAR 가동 — ARView 부착을 기다리지 않음 (cold start 단축).
        prewarmCameraPreview()
    }

    /// 스캔 구성(트래킹+LiDAR 메시+raw sceneDepth)이 현재 세션에서 돌아가는 중인지.
    private(set) var scanConfigActive = false
    /// 스캔 직후 커버리지 등 무거운 작업을 잠시 미룸(메시 수집·표시와 분리).
    private var heavyWorkAllowedAfter: CFTimeInterval = 0
    /// 볼 지정 전까지 메시 정점을 촘촘히 수집.
    private(set) var meshCaptureBurstActive = false

    /// 메시 오버레이를 켜도 되는지 (스캔 진행 중만 — idle 워밍업은 화면에 표시하지 않음).
    var meshVisualizationAllowed: Bool {
        switch flowState {
        case .placingBall, .walkingToHole, .placingHole, .returningToBall, .preparing:
            return true
        default:
            return false
        }
    }

    /// idle 워밍업 중 — 표시는 숨기고 메시 지오메트리만 미리 빌드해 시작 버튼에서 즉시 공개.
    var meshWarmupActive: Bool {
        flowState == .idle && scanConfigActive
    }

    /// 스캔용 ARKit 구성. 분류(classification)와 smoothedSceneDepth는 쓰지 않으므로
    /// 요청하지 않는다(초기 가동 부하·발열 절감, 정확도 영향 없음 — 융합은 raw depth 사용).
    private static func makeScanConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.sceneReconstruction = .mesh
        configuration.frameSemantics.insert(.sceneDepth)
        return configuration
    }

    /// 화면 진입 직후 LiDAR 메시 파이프라인을 즉시 올린다(정점 수집·표시는 스캔 시작까지 끔).
    func prewarmCameraPreview() {
#if !targetEnvironment(simulator)
        guard flowState == .idle else { return }
        prewarmLiDARPipelineIfNeeded()
#endif
    }

    func prewarmSession() {
        prewarmCameraPreview()
    }

    /// idle 동안 LiDAR+depth 파이프라인을 미리 올려 둔다(정점 수집·표시는 끔).
    /// 시작 버튼에서는 session.run을 생략해 메인스레드 행업을 피한다.
    private func prewarmLiDARPipelineIfNeeded() {
#if !targetEnvironment(simulator)
        guard flowState == .idle else { return }
        guard !scanConfigActive else { return }
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        else {
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            session.run(configuration, options: [])
            return
        }
        meshCaptureEnabled = false
        session.run(Self.makeScanConfiguration(), options: [])
        scanConfigActive = true
        // ARKit이 내부 ARMeshAnchor만 쌓음 — 표시·정점 복사는 스캔 시작 후.
#endif
    }

    private func removeMeshAnchorsFromSession() {
        guard let frame = session.currentFrame else { return }
        for anchor in frame.anchors where anchor is ARMeshAnchor {
            session.remove(anchor: anchor)
        }
    }

    /// 워밍업으로 이미 있는 메시를 수집 버퍼·카운트에 즉시 반영.
    private func snapshotExistingMeshAnchors() {
        guard let frame = session.currentFrame else { return }
        let meshes = frame.anchors.filter { $0 is ARMeshAnchor }
        guard !meshes.isEmpty else { return }
        lastMeshCaptureTime = 0
        captureMeshAnchors(
            meshes,
            frameTimestamp: frame.timestamp,
            cameraTransform: frame.camera.transform
        )
    }

    func startScan() {
        guard flowState == .idle || isTerminalState else { return }

        let reusingPrewarmedPipeline = scanConfigActive

        // UI·상태 — session.run / queue.sync 금지
        completedScan = nil
        ballAnchor = nil
        holeAnchor = nil
        cameraStartPose = nil
        cameraReturnPose = nil
        placementRequest = nil
        trackingEvents.removeAll(keepingCapacity: true)
        guidanceTrackingEvents.removeAll(keepingCapacity: true)
        guidanceTrackingOK = true
        ballPlacementTrackingOK = true
        holePlacementTrackingOK = true
        guidancePhaseActive = false
        coverageHaptic.prepare()
        startedAt = Date()
        lastMeshCaptureTime = 0
        lastMeshVertexPublishTime = 0
        pendingMeshVertexCount = 0
        meshCaptureBurstActive = true
        heavyWorkAllowedAfter = CACurrentMediaTime() + 0.12

        if reusingPrewarmedPipeline {
            // 워밍업된 ARMeshAnchor·세션 유지 — 버퍼/카운트/session.run 재시작 없음.
            meshCaptureEnabled = true
        } else {
            latestMeshes.removeAll(keepingCapacity: true)
            meshVertexCount = 0
            meshCaptureEnabled = false
        }

        // 커버리지는 메인에서 sync 하지 않음 (행업 원인)
        coverageSnapshot = .empty
        meshCoverageSnapshot = .empty
        coverageQualityMessage = ScanCoverageQuality.normal.message
        lastCoverageHapticStableCount = 0
        lastPublishedCoverageRatio = -1
        coverageTracker.resetAsync()

#if targetEnvironment(simulator)
        trackingDescription = "시뮬레이터 데모"
        meshCaptureEnabled = true
        flowState = .placingBall
        placementMessage = "시뮬레이터: 볼 (0, 0) · 홀 (0, 3m) 데모 기준을 사용합니다."
#else
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            fail("이 기기는 LiDAR 메시 재구성을 지원하지 않습니다.")
            return
        }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            fail("이 기기는 sceneDepth를 지원하지 않습니다.")
            return
        }

        flowState = .placingBall
        placementMessage = "바닥을 향해 천천히 움직이세요. 메시가 쌓이면 볼을 지정할 수 있습니다."
        trackingDescription = "스캔 중"

        if reusingPrewarmedPipeline {
            snapshotExistingMeshAnchors()
        } else {
            let config = Self.makeScanConfiguration()
            session.run(config, options: [])
            scanConfigActive = true
            meshCaptureEnabled = true
        }
#endif
    }

    /// UI에서 "볼 기준점 지정" 버튼을 눌렀을 때.
    func requestBallPlacement() {
        guard flowState == .placingBall else { return }
#if targetEnvironment(simulator)
        applySimulatorBall()
#else
        if trackingLimited {
            placementMessage = "트래킹이 정상일 때 다시 지정하세요."
            return
        }
        placementRequest = .ball
        placementMessage = "화면 중앙을 볼 중심에 맞추고 있습니다…"
#endif
    }

    /// 홀까지 스캔 후 홀 지정 단계로 진입.
    func beginHolePlacement() {
        guard flowState == .walkingToHole, ballAnchor != nil else { return }
        flowState = .placingHole
        placementMessage = "화면 중앙 십자선을 실제 홀컵 중심에 맞춘 뒤 지정하세요."
    }

    /// UI에서 "홀 기준점 지정" 버튼을 눌렀을 때.
    func requestHolePlacement() {
        guard flowState == .placingHole else { return }
#if targetEnvironment(simulator)
        applySimulatorHole()
#else
        if trackingLimited {
            placementMessage = "트래킹이 정상일 때 다시 지정하세요."
            return
        }
        placementRequest = .hole
        placementMessage = "화면 중앙을 홀컵 중심에 맞추고 있습니다…"
#endif
    }

    /// 조준 화면에서 홀 재앵커링 (중앙 raycast).
    func requestHoleReanchor() {
        guard flowState == .complete else { return }
#if targetEnvironment(simulator)
        applySimulatorHoleReanchor()
#else
        if trackingLimited {
            placementMessage = "트래킹이 정상일 때 다시 지정하세요."
            return
        }
        placementRequest = .reanchorHole
        placementMessage = "화면 중앙을 홀컵에 맞추고 재앵커링…"
#endif
    }

    /// ARView 중앙 raycast 성공 시 호출.
    func applyRaycastHit(worldX: Double, worldY: Double, worldZ: Double, timestamp: TimeInterval) {
        guard let kind = placementRequest else { return }
        let pose = ScanPose(
            worldX: worldX,
            worldY: worldY,
            worldZ: worldZ,
            timestamp: timestamp
        )
        // SwiftUI updateUIView 중 @Published 변경 방지
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.placementRequest = nil
            switch kind {
            case .ball:
                self.confirmBallAnchor(pose)
            case .hole:
                self.confirmHoleAnchor(pose)
            case .reanchorHole:
                self.confirmHoleReanchor(pose)
            }
        }
    }

    func reportRaycastFailure(_ reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.placementRequest = nil
            self.placementMessage = reason
        }
    }

    func finishScan() {
        guard flowState == .returningToBall,
              let ballAnchor,
              let holeAnchor,
              let cameraStartPose else { return }
        processCompletedScan(
            ballAnchor: ballAnchor,
            holeAnchor: holeAnchor,
            cameraStartPose: cameraStartPose,
            requireReturnToBall: true
        )
    }

    /// 홀 지정까지 끝난 뒤 높이맵 처리. 왕복은 복귀 카메라, 편도는 드리프트 0.
    private func processCompletedScan(
        ballAnchor: ScanPose,
        holeAnchor: ScanPose,
        cameraStartPose: ScanPose,
        requireReturnToBall: Bool
    ) {
        flowState = .processing

        // UI에 쓰로틀된 정점 수를 최종값으로 맞춤
        meshVertexCount = latestMeshes.values.reduce(0) { $0 + $1.count }

        let pathMode = self.pathMode
        let driftCorrected = pathMode == .roundTrip

#if targetEnvironment(simulator)
        let returnCamera: ScanPose
        if requireReturnToBall || pathMode == .roundTrip {
            returnCamera = ScanPose(
                worldX: 0,
                worldY: 1.208,
                worldZ: 0,
                timestamp: 20
            )
        } else {
            // 편도: 시작 카메라와 동일 높이 → 드리프트 0
            returnCamera = ScanPose(
                worldX: cameraStartPose.worldX,
                worldY: cameraStartPose.worldY,
                worldZ: cameraStartPose.worldZ,
                timestamp: max(cameraStartPose.timestamp + 10, 10)
            )
        }
        let vertices = Self.syntheticVertices()
        let surfaceSource = "simulator_synthetic"
        let surfaceVertexCount = vertices.count
        meshCaptureEnabled = false
        resetCoverageState()
        cameraReturnPose = returnCamera

        let selectedSigma = sigma
        let events = trackingEvents
        let scanStartedAt = startedAt
        let limitedRatio = Self.limitedRatio(
            events: events,
            start: cameraStartPose.timestamp,
            end: returnCamera.timestamp
        )
        let ballOK = ballPlacementTrackingOK
        let holeOK = holePlacementTrackingOK
        let pipelineReturn = returnCamera
        Task.detached(priority: .userInitiated) {
            do {
                let result = try TerrainPipeline.process(
                    vertices: vertices,
                    startPose: ballAnchor,
                    holePose: holeAnchor,
                    returnPose: pipelineReturn,
                    sigma: selectedSigma,
                    cameraStartPose: cameraStartPose,
                    cameraReturnPose: pipelineReturn
                )
                let transform = try ScanCoordinateTransform(ball: ballAnchor, hole: holeAnchor)
                let holeDistance = hypot(
                    holeAnchor.worldX - ballAnchor.worldX,
                    holeAnchor.worldZ - ballAnchor.worldZ
                )
                let scan = CompletedScan(
                    id: Self.scanIdentifier(),
                    result: result,
                    trackingEvents: events,
                    limitedTrackingRatio: limitedRatio,
                    startedAt: scanStartedAt,
                    ballAnchor: ballAnchor,
                    holeAnchor: holeAnchor,
                    cameraStartPose: cameraStartPose,
                    cameraReturnPose: pipelineReturn,
                    holeDistance: holeDistance,
                    scanTransform: transform,
                    referenceMethod: Self.referenceMethod,
                    ballPlacementTrackingOK: ballOK,
                    holePlacementTrackingOK: holeOK,
                    driftCorrected: driftCorrected,
                    pathMode: pathMode,
                    surfaceSource: surfaceSource,
                    surfaceVertexCount: surfaceVertexCount
                )
                await MainActor.run {
                    self.stopLiDARReconstructionKeepingWorld()
                    self.resetCoverageState()
                    self.completedScan = scan
                    self.guidancePhaseActive = true
                    self.guidanceTrackingEvents.removeAll()
                    self.guidanceTrackingOK = !self.trackingLimited
                    let modeLabel = driftCorrected ? "왕복·드리프트보정" : "편도·드리프트미보정"
                    self.placementMessage = String(
                        format: "기준: AR raycast · 볼-홀 %.2fm · %@",
                        holeDistance,
                        modeLabel
                    )
                    self.flowState = .complete
                }
            } catch {
                await MainActor.run {
                    self.stopLiDARReconstructionKeepingWorld()
                    self.resetCoverageState()
                    self.fail(error.localizedDescription)
                }
            }
        }
#else
        let returnCamera: ScanPose
        if requireReturnToBall {
            guard let pose = currentCameraPose() else {
                fail("볼 복귀 위치를 기록하지 못했습니다.")
                return
            }
            returnCamera = pose
        } else {
            // 편도: 홀에서 찍은 현재 카메라 timestamp만 쓰고, Y는 시작과 동일하게 고정해 드리프트=0
            let now = currentCameraPose()
            returnCamera = ScanPose(
                worldX: cameraStartPose.worldX,
                worldY: cameraStartPose.worldY,
                worldZ: cameraStartPose.worldZ,
                timestamp: now?.timestamp ?? cameraStartPose.timestamp + 1
            )
        }
        cameraReturnPose = returnCamera
        placementMessage = "지면 융합·높이맵 처리 중…"
        // 정점 스냅샷은 이미 확보. LiDAR 종료는 완료 직전으로 미뤄
        // 편도에서 홀 자리에서 session 재구성 → 조준선 좌표 어긋남을 줄인다.
        meshCaptureEnabled = false

        let meshSnapshot = latestMeshes
        let selectedSigma = sigma
        let events = trackingEvents
        let scanStartedAt = startedAt
        let limitedRatio = Self.limitedRatio(
            events: events,
            start: cameraStartPose.timestamp,
            end: returnCamera.timestamp
        )
        let ballOK = ballPlacementTrackingOK
        let holeOK = holePlacementTrackingOK
        let pipelineReturn = returnCamera
        let coverage = coverageTracker

        Task.detached(priority: .userInitiated) {
            // flatMap·융합은 메인 밖에서 — 워치독/히칭 방지
            let rawMeshVertices = Self.filterMeshVerticesForTerrain(
                meshSnapshot.values.flatMap { $0 },
                ball: ballAnchor,
                hole: holeAnchor
            )
            let fusedVertices = await coverage.fusedGroundVerticesAsync(
                ball: ballAnchor,
                hole: holeAnchor
            )
            let usesFusedDepth = fusedVertices.count >= 100
            let vertices = usesFusedDepth ? fusedVertices : rawMeshVertices
            let surfaceSource = usesFusedDepth ? "temporal_scene_depth" : "arkit_mesh_fallback"
            let surfaceVertexCount = vertices.count

            await MainActor.run {
                self.placementMessage = usesFusedDepth
                    ? "다중 프레임 깊이 융합 \(fusedVertices.count.formatted())점 처리 중…"
                    : "깊이 융합 관측 부족 · AR 메시 \(rawMeshVertices.count.formatted())점 처리 중…"
            }

            do {
                let result = try TerrainPipeline.process(
                    vertices: vertices,
                    startPose: ballAnchor,
                    holePose: holeAnchor,
                    returnPose: pipelineReturn,
                    sigma: selectedSigma,
                    cameraStartPose: cameraStartPose,
                    cameraReturnPose: pipelineReturn
                )
                let transform = try ScanCoordinateTransform(ball: ballAnchor, hole: holeAnchor)
                let holeDistance = hypot(
                    holeAnchor.worldX - ballAnchor.worldX,
                    holeAnchor.worldZ - ballAnchor.worldZ
                )
                let scan = CompletedScan(
                    id: Self.scanIdentifier(),
                    result: result,
                    trackingEvents: events,
                    limitedTrackingRatio: limitedRatio,
                    startedAt: scanStartedAt,
                    ballAnchor: ballAnchor,
                    holeAnchor: holeAnchor,
                    cameraStartPose: cameraStartPose,
                    cameraReturnPose: pipelineReturn,
                    holeDistance: holeDistance,
                    scanTransform: transform,
                    referenceMethod: Self.referenceMethod,
                    ballPlacementTrackingOK: ballOK,
                    holePlacementTrackingOK: holeOK,
                    driftCorrected: driftCorrected,
                    pathMode: pathMode,
                    surfaceSource: surfaceSource,
                    surfaceVertexCount: surfaceVertexCount
                )
                await MainActor.run {
                    self.stopLiDARReconstructionKeepingWorld()
                    self.resetCoverageState()
                    self.completedScan = scan
                    self.guidancePhaseActive = true
                    self.guidanceTrackingEvents.removeAll()
                    self.guidanceTrackingOK = !self.trackingLimited
                    let modeLabel = driftCorrected ? "왕복·드리프트보정" : "편도·드리프트미보정"
                    self.placementMessage = String(
                        format: "기준: AR raycast · 볼-홀 %.2fm · %@",
                        holeDistance,
                        modeLabel
                    )
                    self.flowState = .complete
                }
            } catch {
                await MainActor.run {
                    self.stopLiDARReconstructionKeepingWorld()
                    self.resetCoverageState()
                    self.fail(error.localizedDescription)
                }
            }
        }
#endif
    }

    /// 메시 폴백용: 발·깃대·솟은 blob 제거 + 볼-홀 복도 밖 대량 정점 축소.
    private static func filterMeshVerticesForTerrain(
        _ vertices: [ScanVertex],
        ball: ScanPose,
        hole: ScanPose
    ) -> [ScanVertex] {
        let points = vertices.map {
            GroundScanFilter.Point(worldX: $0.worldX, worldY: $0.worldY, worldZ: $0.worldZ)
        }
        var reject = GroundScanFilter.combinedFeatureRejectionMask(points)
        let ceiling = ball.worldY + GroundScanFilter.absoluteAboveBallMeters
        for (index, point) in points.enumerated() where point.worldY > ceiling {
            reject[index] = true
        }

        var kept: [ScanVertex] = []
        kept.reserveCapacity(min(vertices.count, 80_000))
        var outsideIndex = 0
        for (index, vertex) in vertices.enumerated() {
            if reject[index] { continue }
            let inside = Self.isNearPuttCorridor(
                x: vertex.worldX,
                z: vertex.worldZ,
                ball: ball,
                hole: hole
            )
            if inside {
                kept.append(vertex)
            } else {
                outsideIndex += 1
                if outsideIndex % 8 == 0 {
                    kept.append(vertex)
                }
            }
            if kept.count >= 120_000 { break }
        }
        return kept
    }

    private static func isNearPuttCorridor(
        x: Double,
        z: Double,
        ball: ScanPose,
        hole: ScanPose,
        lateralMargin: Double = 1.4,
        endpointMargin: Double = 0.6
    ) -> Bool {
        let dx = hole.worldX - ball.worldX
        let dz = hole.worldZ - ball.worldZ
        let length = hypot(dx, dz)
        guard length > 1e-6 else {
            return hypot(x - ball.worldX, z - ball.worldZ) <= lateralMargin + endpointMargin
        }
        let ux = dx / length
        let uz = dz / length
        let px = x - ball.worldX
        let pz = z - ball.worldZ
        let along = px * ux + pz * uz
        let lateral = abs(px * (-uz) + pz * ux)
        return along >= -endpointMargin
            && along <= length + endpointMargin
            && lateral <= lateralMargin
    }

    func reset() {
        ballAnchor = nil
        holeAnchor = nil
        cameraStartPose = nil
        cameraReturnPose = nil
        placementRequest = nil
        placementMessage = nil
        latestMeshes.removeAll()
        completedScan = nil
        meshVertexCount = 0
        meshCaptureEnabled = false
        meshCaptureBurstActive = false
        guidancePhaseActive = false
        guidanceTrackingEvents.removeAll()
        guidanceTrackingOK = true
        resetCoverageState()
        flowState = .idle
        // LiDAR 끄고, idle에서 다시 워밍업
        stopLiDARReconstructionKeepingWorld()
        prewarmCameraPreview()
    }

    private func resetCoverageState() {
        coverageSnapshot = .empty
        meshCoverageSnapshot = .empty
        coverageQualityMessage = ScanCoverageQuality.normal.message
        lastCoverageHapticStableCount = 0
        lastPublishedCoverageRatio = -1
        coverageTracker.resetAsync()
    }

    private func applyCoverageSnapshot(_ snapshot: ScanCoverageSnapshot) {
        meshCoverageSnapshot = snapshot

        let ratioDelta = abs(snapshot.stableRatio - lastPublishedCoverageRatio)
        let qualityChanged = snapshot.quality.message != coverageQualityMessage
        let statusChanged = snapshot.statusLine != coverageSnapshot.statusLine
        let cellDelta = abs(snapshot.stableCellCount - coverageSnapshot.stableCellCount)
        let shouldPublish = qualityChanged || statusChanged || ratioDelta >= 0.03 || cellDelta >= 6
            || coverageSnapshot.stableCellCount == 0

        if shouldPublish {
            coverageSnapshot = snapshot
            coverageQualityMessage = snapshot.quality.message
            lastPublishedCoverageRatio = snapshot.stableRatio
        }

        let gained = snapshot.stableCellCount - lastCoverageHapticStableCount
        if gained >= 8 {
            coverageHaptic.impactOccurred()
            lastCoverageHapticStableCount = snapshot.stableCellCount
        }
    }

    private var isCoverageActiveState: Bool {
        switch flowState {
        case .preparing, .placingBall, .walkingToHole, .placingHole, .returningToBall:
            return true
        default:
            return false
        }
    }

    /// ARMeshAnchor 정점 수집 (스캔 진행 중만).
    private var isMeshCaptureState: Bool {
        meshCaptureEnabled && isCoverageActiveState
    }

    /// 스캔 데이터 수집이 끝나면 LiDAR 메시·sceneDepth를 끄고 월드 트래킹만 유지한다.
    /// (조준선·재앵커용 카메라 세션은 유지, 배터리·폴리곤 오버레이 절약)
    private func stopLiDARReconstructionKeepingWorld() {
        meshCaptureEnabled = false
        if let frame = session.currentFrame {
            for anchor in frame.anchors where anchor is ARMeshAnchor {
                session.remove(anchor: anchor)
            }
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        // 홀 재앵커 raycast용 수평면만. 메시/깊이 재구성은 끔.
        configuration.planeDetection = [.horizontal]
        // resetTracking / removeExistingAnchors 금지 — 볼·홀 월드 좌표 유지
        session.run(configuration, options: [])
        scanConfigActive = false
    }

    // MARK: - Placement confirms

    private func confirmBallAnchor(_ pose: ScanPose) {
        guard flowState == .placingBall else { return }
        ballAnchor = pose
        if let transform = session.currentFrame?.camera.transform {
            coverageTracker.captureTiltReference(from: transform)
        }
        cameraStartPose = currentCameraPose() ?? ScanPose(
            worldX: pose.worldX,
            worldY: pose.worldY + 0.9,
            worldZ: pose.worldZ,
            timestamp: pose.timestamp
        )
        ballPlacementTrackingOK = !trackingLimited
        placementMessage = String(
            format: "볼 기준점 지정 완료 (%.2f, %.2f, %.2f)",
            pose.worldX, pose.worldY, pose.worldZ
        )
        flowState = .walkingToHole
    }

    private func confirmHoleAnchor(_ pose: ScanPose) {
        guard flowState == .placingHole, let ball = ballAnchor else { return }
        let distance = hypot(pose.worldX - ball.worldX, pose.worldZ - ball.worldZ)
        guard distance >= Self.minimumHoleDistance else {
            placementMessage = "볼과 홀이 너무 가깝습니다(5cm 미만). 다시 지정하세요."
            return
        }
        holeAnchor = pose
        holePlacementTrackingOK = !trackingLimited
        placementMessage = String(
            format: "홀 기준점 지정 완료 · 거리 %.2fm",
            distance
        )
        if pathMode == .oneWay {
            guard let cameraStartPose else {
                fail("볼 지정 시 카메라 pose가 없습니다.")
                return
            }
            processCompletedScan(
                ballAnchor: ball,
                holeAnchor: pose,
                cameraStartPose: cameraStartPose,
                requireReturnToBall: false
            )
        } else {
            flowState = .returningToBall
        }
    }

    private func confirmHoleReanchor(_ pose: ScanPose) {
        guard flowState == .complete, let scan = completedScan else { return }
        let distance = hypot(
            pose.worldX - scan.ballAnchor.worldX,
            pose.worldZ - scan.ballAnchor.worldZ
        )
        guard distance >= Self.minimumHoleDistance else {
            placementMessage = "볼과 홀이 너무 가깝습니다. 재앵커 실패."
            return
        }
        do {
            let transform = try ScanCoordinateTransform(ball: scan.ballAnchor, hole: pose)
            completedScan = CompletedScan(
                id: scan.id,
                result: scan.result,
                trackingEvents: scan.trackingEvents,
                limitedTrackingRatio: scan.limitedTrackingRatio,
                startedAt: scan.startedAt,
                ballAnchor: scan.ballAnchor,
                holeAnchor: pose,
                cameraStartPose: scan.cameraStartPose,
                cameraReturnPose: scan.cameraReturnPose,
                holeDistance: distance,
                scanTransform: transform,
                referenceMethod: Self.referenceMethod,
                ballPlacementTrackingOK: scan.ballPlacementTrackingOK,
                holePlacementTrackingOK: !trackingLimited,
                driftCorrected: scan.driftCorrected,
                pathMode: scan.pathMode,
                surfaceSource: scan.surfaceSource,
                surfaceVertexCount: scan.surfaceVertexCount
            )
            holeAnchor = pose
            guidanceTrackingEvents.removeAll()
            guidanceTrackingOK = true
            placementMessage = String(format: "홀 재앵커 완료 · %.2fm", distance)
            trackingDescription = "홀 재앵커 완료"
        } catch {
            placementMessage = "홀 재앵커 실패: \(error.localizedDescription)"
        }
    }

#if targetEnvironment(simulator)
    private func applySimulatorBall() {
        let ball = ScanPose(worldX: 0, worldY: 0.3, worldZ: 0, timestamp: 0)
        ballAnchor = ball
        cameraStartPose = ScanPose(worldX: 0, worldY: 1.2, worldZ: 0, timestamp: 0)
        ballPlacementTrackingOK = true
        placementMessage = "시뮬레이터 볼 기준 (0, 0.3, 0)"
        flowState = .walkingToHole
    }

    private func applySimulatorHole() {
        let hole = ScanPose(worldX: 0, worldY: 0.33, worldZ: 3, timestamp: 10)
        holeAnchor = hole
        holePlacementTrackingOK = true
        placementMessage = "시뮬레이터 홀 기준 (0, 0.33, 3) · 거리 3.00m"
        if pathMode == .oneWay {
            guard let cameraStartPose, let ballAnchor else { return }
            processCompletedScan(
                ballAnchor: ballAnchor,
                holeAnchor: hole,
                cameraStartPose: cameraStartPose,
                requireReturnToBall: false
            )
        } else {
            flowState = .returningToBall
        }
    }

    private func applySimulatorHoleReanchor() {
        confirmHoleReanchor(ScanPose(worldX: 0, worldY: 0.33, worldZ: 3, timestamp: Date().timeIntervalSince1970))
    }
#endif

    private var isTerminalState: Bool {
        switch flowState {
        case .complete, .failed:
            return true
        default:
            return false
        }
    }

    private func currentCameraPose() -> ScanPose? {
        guard let frame = session.currentFrame else { return nil }
        let translation = frame.camera.transform.columns.3
        return ScanPose(
            worldX: Double(translation.x),
            worldY: Double(translation.y),
            worldZ: Double(translation.z),
            timestamp: frame.timestamp
        )
    }

    private func fail(_ message: String) {
        session.pause()
        scanConfigActive = false
        meshCaptureEnabled = true
        guidancePhaseActive = false
        placementRequest = nil
        resetCoverageState()
        flowState = .failed(message)
    }

    private static func scanIdentifier() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "scan-\(formatter.string(from: Date()))"
    }

    private static func limitedRatio(
        events: [TrackingEvent],
        start: TimeInterval,
        end: TimeInterval
    ) -> Double {
        let duration = end - start
        guard duration > 0 else { return 0 }
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var limitedDuration = 0.0
        var currentLimited = false
        var cursor = start
        for event in sorted where event.timestamp >= start && event.timestamp <= end {
            if currentLimited {
                limitedDuration += max(event.timestamp - cursor, 0)
            }
            currentLimited = event.isLimited
            cursor = event.timestamp
        }
        if currentLimited {
            limitedDuration += max(end - cursor, 0)
        }
        return min(max(limitedDuration / duration, 0), 1)
    }

#if targetEnvironment(simulator)
    private static func syntheticVertices() -> [ScanVertex] {
        var vertices: [ScanVertex] = []
        for row in 0...60 {
            for column in -20...20 {
                let z = Double(row) * 0.05
                let x = Double(column) * 0.05
                let progress = z / 3
                let physicalHeight = 0.3 + 0.01 * z + 0.002 * sin(x * 4)
                let drift = 0.008 * progress
                vertices.append(
                    ScanVertex(
                        worldX: x,
                        worldY: physicalHeight + drift,
                        worldZ: z,
                        timestamp: progress * 20
                    )
                )
            }
        }
        return vertices
    }
#endif
}

extension ARScanSessionController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let state = flowState
        if state == .preparing {
            DispatchQueue.main.async {
                guard self.flowState == .preparing else { return }
                // 첫 프레임은 카메라 pose가 아니라 트래킹 준비 완료 신호로만 쓴다.
                self.flowState = .placingBall
                self.placementMessage = "화면 중앙 십자선을 실제 볼 중심에 맞춘 뒤 지정하세요."
            }
        }

        // Polycam형 커버리지: 스캔 직후 유예 뒤에 depth 샘플링 (첫 LiDAR 가동과 겹치면 행업).
        if isCoverageActiveState,
           meshCaptureEnabled,
           CACurrentMediaTime() >= heavyWorkAllowedAfter {
            let limited = trackingLimited
            let ballY = self.ballAnchor?.worldY
            coverageTracker.process(frame: frame, trackingLimited: limited, ballY: ballY) { [weak self] snapshot in
                guard let self, self.isCoverageActiveState else { return }
                self.applyCoverageSnapshot(snapshot)
            }
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard isMeshCaptureState else { return }
        captureMeshAnchors(
            anchors,
            frameTimestamp: session.currentFrame?.timestamp ?? 0,
            cameraTransform: session.currentFrame?.camera.transform
        )
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard isMeshCaptureState else { return }
        captureMeshAnchors(
            anchors,
            frameTimestamp: session.currentFrame?.timestamp ?? 0,
            cameraTransform: session.currentFrame?.camera.transform
        )
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard meshCaptureEnabled else { return }
        let identifiers = anchors.map(\.identifier)
        DispatchQueue.main.async {
            for identifier in identifiers {
                self.latestMeshes.removeValue(forKey: identifier)
            }
            self.meshVertexCount = self.latestMeshes.values.reduce(0) { $0 + $1.count }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let description: String
        let limited: Bool
        switch camera.trackingState {
        case .normal:
            description = "정상"
            limited = false
        case .notAvailable:
            description = "사용 불가"
            limited = true
        case .limited(let reason):
            limited = true
            switch reason {
            case .initializing:
                description = "제한됨: 초기화 중"
            case .excessiveMotion:
                description = "제한됨: 움직임이 너무 빠름"
            case .insufficientFeatures:
                description = "제한됨: 특징점 부족"
            case .relocalizing:
                description = "제한됨: 위치 재탐색 중"
            @unknown default:
                description = "제한됨"
            }
        }
        let timestamp = session.currentFrame?.timestamp ?? 0
        DispatchQueue.main.async {
            self.trackingDescription = description
            self.trackingLimited = limited
            switch self.flowState {
            case .preparing, .placingBall, .walkingToHole, .placingHole, .returningToBall:
                self.trackingEvents.append(
                    TrackingEvent(timestamp: timestamp, state: description, isLimited: limited)
                )
            default:
                break
            }
            if self.guidancePhaseActive {
                self.guidanceTrackingEvents.append(
                    TrackingEvent(timestamp: timestamp, state: description, isLimited: limited)
                )
                if limited {
                    self.guidanceTrackingOK = false
                }
            }
        }
    }

    private static let maxMeshVerticesTotal = 160_000
    private static let maxVerticesPerAnchor = 28_000

    private func captureMeshAnchors(
        _ anchors: [ARAnchor],
        frameTimestamp: TimeInterval,
        cameraTransform: simd_float4x4?
    ) {
        // 스로틀 판단은 메인에서, 정점 복사·필터는 백그라운드에서. 볼 지정 전(burst)은 촘촘히.
        let minInterval: TimeInterval = meshCaptureBurstActive ? 0.06 : 0.35
        guard frameTimestamp - lastMeshCaptureTime >= minInterval else { return }
        lastMeshCaptureTime = frameTimestamp

        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }
        let camX = cameraTransform.map { Double($0.columns.3.x) }
        let camZ = cameraTransform.map { Double($0.columns.3.z) }
        let ballY = ballAnchor?.worldY

        meshExtractionQueue.async { [weak self] in
            var snapshots: [(UUID, [ScanVertex])] = []
            for meshAnchor in meshAnchors {
                let source = meshAnchor.geometry.vertices
                var points: [GroundScanFilter.Point] = []
                points.reserveCapacity(min(source.count, Self.maxVerticesPerAnchor))
                let step = max(1, source.count / Self.maxVerticesPerAnchor)
                for index in Swift.stride(from: 0, to: source.count, by: step) {
                    let pointer = source.buffer.contents()
                        .advanced(by: source.offset + source.stride * index)
                        .assumingMemoryBound(to: SIMD3<Float>.self)
                    let local = pointer.pointee
                    let world = meshAnchor.transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                    points.append(
                        GroundScanFilter.Point(
                            worldX: Double(world.x),
                            worldY: Double(world.y),
                            worldZ: Double(world.z)
                        )
                    )
                }
                // 발·깃대 필터: depth 융합·최종 지형·볼 지정 후 메시 저장에 적용.
                // 볼 지정 전에는 수직 기둥(깃대)만 제거 — 발 앞 지면 보호.
                if let ballY {
                    points = GroundScanFilter.rejectAboveBallReference(points: points, ballY: ballY)
                }
                points = GroundScanFilter.rejectVerticalPoleLikeProtrusions(points)
                let vertices = points.map {
                    ScanVertex(
                        worldX: $0.worldX,
                        worldY: $0.worldY,
                        worldZ: $0.worldZ,
                        timestamp: frameTimestamp
                    )
                }
                snapshots.append((meshAnchor.identifier, vertices))
            }
            guard !snapshots.isEmpty else { return }

            DispatchQueue.main.async {
                guard let self else { return }
                for (identifier, vertices) in snapshots {
                    self.latestMeshes[identifier] = vertices
                }
                self.pruneLatestMeshesIfNeeded(
                    cameraX: camX,
                    cameraZ: camZ
                )
                let total = self.latestMeshes.values.reduce(0) { $0 + $1.count }
                self.pendingMeshVertexCount = total
                let crossedReady = total >= Self.meshReadyVertexThreshold
                    && self.meshVertexCount < Self.meshReadyVertexThreshold
                if crossedReady {
                    self.meshCaptureBurstActive = false
                }
                let publishInterval: TimeInterval = self.meshCaptureBurstActive ? 0.12 : 0.5
                let publishDelta = self.meshCaptureBurstActive ? 80 : 500
                if crossedReady
                    || frameTimestamp - self.lastMeshVertexPublishTime >= publishInterval
                    || abs(total - self.meshVertexCount) >= publishDelta {
                    self.meshVertexCount = total
                    self.lastMeshVertexPublishTime = frameTimestamp
                }
            }
        }
    }

    /// 총 정점 상한 초과 시 카메라에서 먼 앵커부터 제거.
    private func pruneLatestMeshesIfNeeded(cameraX: Double?, cameraZ: Double?) {
        var total = latestMeshes.values.reduce(0) { $0 + $1.count }
        guard total > Self.maxMeshVerticesTotal else { return }
        let refX = cameraX ?? ballAnchor?.worldX ?? 0
        let refZ = cameraZ ?? ballAnchor?.worldZ ?? 0
        let ranked = latestMeshes.map { id, verts -> (UUID, Double, Int) in
            guard let first = verts.first else { return (id, .greatestFiniteMagnitude, 0) }
            let dist = hypot(first.worldX - refX, first.worldZ - refZ)
            return (id, dist, verts.count)
        }
        .sorted { $0.1 > $1.1 }
        for entry in ranked {
            guard total > Self.maxMeshVerticesTotal else { break }
            latestMeshes.removeValue(forKey: entry.0)
            total -= entry.2
        }
    }
}
