import ARKit
import Combine
import Foundation
import PuttPhysicsKit
@preconcurrency import RealityKit
import simd
import UIKit

enum ScanFlowState: Equatable {
    case idle
    case placingBall
    case walkingToHole
    case placingHole
    case processing
    case complete
    case failed(String)
}

/// 지정 계산 모드. 둘 다 홀 지정 직후 경로를 계산한다.
/// 볼홀지정계산: 실볼이 그대로면 바로 조준. 볼홀볼지정계산: 돌아와 실볼을 재지정.
enum ScanPathMode: String, CaseIterable, Identifiable {
    case oneWay
    case roundTrip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneWay: return "볼홀지정계산"
        case .roundTrip: return "볼홀볼지정계산"
        }
    }

    var detail: String {
        switch self {
        case .oneWay:
            return "홀 지정 직후 경로를 계산·표시합니다. 조준하는 동안 RGB·LiDAR로 실볼을 감지해 AR 볼을 맞춥니다."
        case .roundTrip:
            return "홀 지정 직후 경로를 계산합니다. 볼로 돌아와 조준하면 실볼을 자동 정렬합니다. 실패 시에만 재지정하세요."
        }
    }

    /// 조준 전 실볼 재지정이 필요한지. 자동 정렬이 성공하면 해제된다.
    var requiresBallReanchor: Bool {
        self == .roundTrip
    }
}

enum VisualBallLockStatus: Equatable {
    case idle
    case waitingForView
    case searching
    case candidate
    case aligned
    case locked(offsetMeters: Double)

    var isSettled: Bool {
        switch self {
        case .aligned, .locked:
            return true
        default:
            return false
        }
    }

    var shortLabel: String? {
        switch self {
        case .idle:
            return nil
        case .waitingForView:
            return "실볼을 화면에"
        case .searching:
            return "실볼 감지 중"
        case .candidate:
            return "후보 · 확인 필요"
        case .aligned:
            return "실볼 일치"
        case .locked:
            return "실볼 정렬"
        }
    }
}

enum PlacementKind: Equatable {
    case ball
    case hole
    case reanchorHole
    case reanchorBall
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
    /// 조준·홀 재앵커에 쓰는 현재 볼→홀 변환.
    let scanTransform: ScanCoordinateTransform
    /// 높이맵을 만든 볼→홀 변환. 재앵커해도 바꾸지 않는다(등고·격자 샘플 정합).
    let terrainTransform: ScanCoordinateTransform
    /// 높이맵을 만든 홀 지면점. 재앵커해도 바꾸지 않는다.
    let terrainHoleAnchor: ScanPose
    let referenceMethod: String
    let ballPlacementTrackingOK: Bool
    let holePlacementTrackingOK: Bool
    /// 볼 복귀 카메라로 드리프트를 보정했으면 true.
    let driftCorrected: Bool
    let pathMode: ScanPathMode
    /// 스캔 완료 시점의 지정 계산·복도 프리셋.
    let fieldMode: ScanFieldMode
    /// `temporal_scene_depth` 또는 관측 부족 시 `arkit_mesh_fallback`.
    let surfaceSource: String
    let surfaceVertexCount: Int
    let lidarProfile: LiDARDeviceProfile
    /// 볼 뒤 사선 Phase 품질 로그.
    let behindBallSweepStats: BehindBallSweepGate.Stats
    /// STEP 3 걷기 복도 Phase 품질 로그.
    let walkCorridorStats: WalkCorridorGate.Stats

    /// 조준 오버레이용 현재 볼. 물리는 `physicsStartPose`를 쓴다.
    var startPose: ScanPose { ballAnchor }
    /// 조준 오버레이용 현재 홀. 물리는 `physicsHolePose`를 쓴다.
    var holePose: ScanPose { holeAnchor }
    /// 높이맵 원점(스캔 당시 볼). 재지정해도 바뀌지 않는다.
    var physicsStartPose: ScanPose { terrainTransform.origin }
    /// 높이맵 홀. 재앵커해도 바뀌지 않는다.
    var physicsHolePose: ScanPose { terrainHoleAnchor }
    var returnPose: ScanPose { cameraReturnPose }
}

final class ARScanSessionController: NSObject, ObservableObject, @unchecked Sendable {
    static let referenceMethod = "ar_raycast"
    static let minimumHoleDistance = 0.05

    let session = ARSession()
    let lidarProfile = LiDARDeviceProfile.resolve()

    @Published private(set) var flowState: ScanFlowState = .idle
    @Published private(set) var trackingDescription = "대기 중"
    @Published private(set) var trackingLimited = false
    @Published private(set) var meshVertexCount = 0
    @Published private(set) var sceneDepthReady = false
    @Published private(set) var completedScan: CompletedScan?
    @Published private(set) var guidanceTrackingEvents: [TrackingEvent] = []
    @Published private(set) var guidanceTrackingOK = true
    @Published private(set) var ballAnchor: ScanPose?
    @Published private(set) var holeAnchor: ScanPose?
    @Published private(set) var placementMessage: String?
    /// 스캔 중 LiDAR 권장 화면 구역·틀기 게이지.
    @Published private(set) var lidarTwistGuidance: LiDARTwistGuidanceState?
    /// AR 뷰가 화면 중앙 raycast를 수행하도록 요청한다.
    @Published var placementRequest: PlacementKind?
    /// 볼홀볼지정계산: 조준 전 실볼 재지정. 높이맵은 다시 계산하지 않는다.
    @Published private(set) var needsBallReanchor = false
    /// 조준 중 RGB·LiDAR 실볼(시판 색) 자동 정렬.
    @Published private(set) var visualBallLockStatus: VisualBallLockStatus = .idle
    /// 하안 근접 백그라운드 보정. OSD/상태를 바꾸지 않는다.
    private(set) var guidanceLiveBallPose: ScanPose?
    /// 감지된 볼 후보. 골퍼가 확인하기 전에는 지정되지 않는다. 볼 없는 스캔도 가능.
    @Published private(set) var pendingDetectedBall: ScanPose?
    /// 1프레임 미리보기(링). 확정은 `pendingDetectedBall`(합의) 또는 십자선.
    @Published private(set) var ballDetectionPreview: ScanPose?
    /// 볼 확정 후 흰 격자 stick을 확정 볼로 다시 심도록 DisplayLink에 알림.
    @Published private(set) var coverageDisplayEpoch = 0
    /// 지면 링 투영(디스플레이 링크 갱신).
    /// When true, placement ring UI hides the hole cup (e.g. floor-address mode).
    var hidesHoleCupRingOverlay = false
    /// 커버리지가 홀 뒤로 얼마나 들어왔는지(최대 1.0m).
    @Published private(set) var pastHoleMeasuredMeters = 0.0
    @Published var sigma = 1.5
    /// 기본 볼홀지정계산. 실볼이 바뀌면 볼홀볼지정계산으로 재지정.
    @Published var pathMode: ScanPathMode = .oneWay {
        didSet {
            if gate1RetestLockRoundTrip, pathMode != .roundTrip {
                pathMode = .roundTrip
            }
        }
    }
    /// 게이트1 전체 스택 재측정용 — 켜면 볼홀볼지정계산만 허용.
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
    private var lastTwistGuidanceUpdate: CFTimeInterval = 0
    private var walkCorridorStatsSnapshot = WalkCorridorGate.Stats.empty
    private var lastWalkTwistInBandSample: CFTimeInterval = 0

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
    private let coverageHaptic: UIImpactFeedbackGenerator
    /// ARMeshAnchor 정점 복사·필터 전용 직렬 큐 — 메인에서 하면 버튼 탭·스캔 중 히칭.
    private let meshExtractionQueue = DispatchQueue(label: "putthink.mesh-extract", qos: .userInitiated)
    private let visualLockQueue = DispatchQueue(label: "putthink.ball-lock", qos: .userInitiated)
    private var visualLockConsensus = GolfBallLockConsensus()
    private let ballPreviewSmoothing = 1.0
    private var visualLockProcessing = false
    private var lastVisualLockTime: TimeInterval = 0

    var currentHoleDistance: Double? {
        guard let ball = ballAnchor, let hole = holeAnchor else { return nil }
        return hypot(hole.worldX - ball.worldX, hole.worldZ - ball.worldZ)
    }

    /// 볼 지정 전에 LiDAR 메시 또는 sceneDepth가 있는지. 흰 커버리지와 무관.
    static let meshReadyVertexThreshold = 80

    /// STEP 3 — 홀이 가까울 수 있으므로 품질 게이트와 무관하게 항상 허용.
    var canBeginHolePlacement: Bool {
        flowState == .walkingToHole
    }

    /// 볼 기준점을 지정해도 될 만큼 메시가 준비됐는지.
    var meshReady: Bool {
#if targetEnvironment(simulator)
        return true
#else
        return sceneDepthReady || meshVertexCount >= Self.meshReadyVertexThreshold
#endif
    }

    override init() {
        coverageHaptic = UIImpactFeedbackGenerator(style: .light)
        super.init()
        session.delegate = self
        applyPathModeForFieldMode()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScanFieldSettingsDidChange),
            name: ScanFieldSettings.didChangeNotification,
            object: nil
        )
        // 상용 스캐너와 같이 앱 기동과 동시에 LiDAR 세션을 올린다(ARView 부착 전에도 가능).
        prewarmLiDARPipelineIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 설정 지정 계산 모드를 pathMode에 반영.
    func applyPathModeForFieldMode() {
        guard !gate1RetestLockRoundTrip else {
            pathMode = .roundTrip
            return
        }
        pathMode = ScanFieldSettings.fieldMode.pathMode
    }

    @objc private func handleScanFieldSettingsDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.applyPathModeForFieldMode()
        }
    }

    /// 스캔 구성(트래킹+LiDAR 메시+raw sceneDepth)이 현재 세션에서 돌아가는 중인지.
    @Published private(set) var scanConfigActive = false
    /// idle 워밍업·스캔 시작 직전 LiDAR session.run 진행 중.
    @Published private(set) var isPrewarmingPipeline = false
    /// 스캔 직후 커버리지 등 무거운 작업을 잠시 미룸(메시 수집·표시와 분리).
    private var heavyWorkAllowedAfter: CFTimeInterval = 0
    /// 볼 지정 전까지 메시 정점을 촘촘히 수집.
    private(set) var meshCaptureBurstActive = false
    /// reset/새 스캔 시 진행 중인 높이맵 Task 완료를 무시한다.
    private var processingGeneration = 0
    private var isResetting = false

    /// idle 화면에서 스캔 시작 버튼을 켤 수 있는지.
    /// 상용 LiDAR 앱과 같이 session.run 직후 바로 시작. tracking.normal 대기는 20초급 멈춤을 만든다.
    var scanStartReady: Bool {
#if targetEnvironment(simulator)
        true
#else
        scanConfigActive && !isPrewarmingPipeline
#endif
    }

    /// ARKit 트래킹이 아직 초기화 중인지 (스캔 시작 대기 표시용).
    @Published private(set) var trackingInitializing = true
    /// idle 워밍업 중 관측된 ARMeshAnchor 수 (시작 버튼 UX용).
    @Published private(set) var warmupMeshAnchorCount = 0

    /// 메시 오버레이를 켜도 되는지 (스캔 진행 중만 — 조준·경로 표시 중에는 겹침 방지).
    var meshVisualizationAllowed: Bool {
        switch flowState {
        case .placingBall, .walkingToHole, .placingHole, .processing:
            return true
        default:
            return false
        }
    }

    /// idle 워밍업 중 — 표시는 숨기고 메시 지오메트리만 미리 빌드해 시작 버튼에서 즉시 공개.
    var meshWarmupActive: Bool {
        flowState == .idle && scanConfigActive
    }

    /// 스캔용 ARKit 구성.
    /// Apple: 쓰지 않는 옵션은 켜지 말 것(분류·평면·환경텍스처는 초기 메시를 늦춘다).
    /// videoFormat은 기본 FOV에 가까운 해상도를 고정한다. 최소 해상도는 중앙 크롭처럼
    /// 잠깐 줌인됐다 돌아오는 체감이 난다.
    /// LiDAR 파이프라인이 올라가고 트래킹 초기화가 끝났을 때만 스캔 시작.
    var scanPipelineReady: Bool {
#if targetEnvironment(simulator)
        return true
#else
        return scanConfigActive && !trackingInitializing
#endif
    }

    private static func makeScanConfiguration(reusing session: ARSession? = nil) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.environmentTexturing = .none
        configuration.sceneReconstruction = .mesh
        configuration.frameSemantics.insert(.sceneDepth)
        if let existing = session?.configuration as? ARWorldTrackingConfiguration {
            // 이미 돌고 있는 포맷을 유지 — 스캔 시작 시 가로↔세로 플래시 방지.
            configuration.videoFormat = existing.videoFormat
        } else if let format = stableScanVideoFormat() {
            configuration.videoFormat = format
        }
        return configuration
    }

    /// 기본 AR 미리보기와 같은 시야각에 가까운 포맷(대략 1920×1440 @ 30).
    private static func stableScanVideoFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let ranked = formats.filter { $0.framesPerSecond >= 30 && $0.framesPerSecond <= 60 }
        let pool = ranked.isEmpty ? formats : ranked
        let targetPixels: CGFloat = 1920 * 1440
        return pool.min { a, b in
            let ap = abs(a.imageResolution.width * a.imageResolution.height - targetPixels)
            let bp = abs(b.imageResolution.width * b.imageResolution.height - targetPixels)
            if ap != bp { return ap < bp }
            // 동점이면 30fps 우선(열·부하).
            return abs(a.framesPerSecond - 30) < abs(b.framesPerSecond - 30)
        }
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

    /// idle 동안 LiDAR+depth 파이프라인을 미리 올린다. session.run은 비동기이므로 여기서 바로 호출한다.
    private var prewarmTaskPending = false

    private func prewarmLiDARPipelineIfNeeded() {
#if !targetEnvironment(simulator)
        guard flowState == .idle else { return }
        guard !scanConfigActive, !prewarmTaskPending else { return }
        ensureIdleLiDARPipelineRunning()
#endif
    }

    /// idle 워밍업·실패 후 reset — session.run으로 LiDAR 파이프라인을 다시 올린다.
    private func ensureIdleLiDARPipelineRunning() {
#if !targetEnvironment(simulator)
        guard flowState == .idle else { return }
        guard !prewarmTaskPending else { return }
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        else { return }

        prewarmTaskPending = true
        isPrewarmingPipeline = true
        meshCaptureEnabled = true
        session.run(Self.makeScanConfiguration(reusing: session), options: [])
        scanConfigActive = true
        warmupMeshAnchorCount = 0
        isPrewarmingPipeline = false
        prewarmTaskPending = false
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
#if !targetEnvironment(simulator)
        if !scanConfigActive {
            prewarmLiDARPipelineIfNeeded()
        }
        guard scanPipelineReady else { return }
#endif

        applyPathModeForFieldMode()

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
        // depth 복사는 백그라운드. 상용 앱처럼 스캔 시작 직후부터 커버리지를 쌓는다.
        heavyWorkAllowedAfter = CACurrentMediaTime()

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
            fail(L10n.failNoLiDAR)
            return
        }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            fail(L10n.failNoDepth)
            return
        }

        if reusingPrewarmedPipeline {
            meshCaptureEnabled = true
            beginPlacingBallPhase()
            // 메인에서 대량 정점 복사를 바로 하지 않음 — 다음 틱에 스냅샷.
            DispatchQueue.main.async { [weak self] in
                self?.snapshotExistingMeshAnchors()
            }
        } else {
            isPrewarmingPipeline = true
            session.run(Self.makeScanConfiguration(reusing: session), options: [])
            scanConfigActive = true
            meshCaptureEnabled = true
            isPrewarmingPipeline = false
            beginPlacingBallPhase()
            DispatchQueue.main.async { [weak self] in
                self?.snapshotExistingMeshAnchors()
            }
        }
#endif
    }

    private func beginPlacingBallPhase() {
        flowState = .placingBall
        resetVisualBallLock()
        visualBallLockStatus = .searching
        placementMessage = "볼이 있으면 십자선을 맞추고 확인하세요. 없으면 십자선 지면을 직접 지정하세요."
        trackingDescription = "스캔 중"
    }

    /// UI에서 볼 지정 확인. 감지는 후보만 올리고, 여기서 골퍼가 확정한다.
    func requestBallPlacement() {
        guard flowState == .placingBall else { return }
#if targetEnvironment(simulator)
        applySimulatorBall()
#else
        if trackingLimited {
            placementMessage = "트래킹이 정상일 때 다시 지정하세요."
            return
        }
        // 합의 후보만 감지 좌표로 확정. 단발 preview는 오탐(우측 하단 등)이 많아 쓰지 않는다.
        if let candidate = pendingDetectedBall {
            confirmBallAnchor(candidate)
            visualBallLockStatus = .locked(offsetMeters: 0)
            markVisualLock(at: candidate)
            pendingDetectedBall = nil
            ballDetectionPreview = nil
            placementMessage = "감지 후보로 볼 지정"
            coverageHaptic.impactOccurred()
            return
        }
        placementMessage = "십자선 지면을 볼 위치로 지정합니다…"
        guard let pose = immediateGroundPose() else {
            placementMessage = "지면을 찾지 못했습니다. 십자선을 잔디/바닥에 맞추고 다시 시도하세요."
            return
        }
        confirmBallAnchor(pose)
        visualBallLockStatus = .locked(offsetMeters: 0)
        markVisualLock(at: pose)
        ballDetectionPreview = nil
        pendingDetectedBall = nil
        coverageHaptic.impactOccurred()
#endif
    }

    /// 홀까지 스캔 후 홀 지정 단계로 진입. 짧은 퍼트도 언제든 가능.
    func beginHolePlacement() {
        guard flowState == .walkingToHole, ballAnchor != nil else { return }
        enterHolePlacement()
    }

    private func enterHolePlacement() {
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
        placementMessage = "화면 중앙을 홀컵 중심에 맞추고 있습니다…"
        guard let pose = immediateGroundPose() else {
            placementMessage = "지면을 찾지 못했습니다. 십자선을 홀컵 중심에 맞추고 다시 시도하세요."
            return
        }
        confirmHoleAnchor(pose)
#endif
    }

    /// 조준 화면에서 홀 재앵커링 (중앙 즉시 raycast).
    func requestHoleReanchor() {
        guard flowState == .complete else { return }
        guard placementRequest == nil else { return }
#if targetEnvironment(simulator)
        applySimulatorHoleReanchor()
#else
        if trackingLimited {
            placementMessage = "트래킹이 정상일 때 다시 지정하세요."
            return
        }
        placementRequest = .reanchorHole
        placementMessage = "화면 중앙을 홀컵에 맞추고 재앵커링…"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.placementRequest = nil }
            guard let pose = self.immediateGroundPose() else {
                self.placementMessage = "홀 재앵커: 지면을 찾지 못했습니다."
                return
            }
            self.confirmHoleReanchor(pose)
        }
#endif
    }

    /// 볼홀볼지정계산: 돌아와 실볼에 맞춰 조준 프레임만 회전. 높이맵 재계산 없음.
    func requestBallReanchor() {
        guard flowState == .complete, completedScan != nil else { return }
        if placementRequest == .reanchorBall {
            if trackingLimited {
                placementMessage = "트래킹이 정상일 때 다시 지정하세요."
                return
            }
            guard let pose = resolvedManualBallPlacementPose() else {
                placementMessage = "지면을 찾지 못했습니다. 십자선을 잔디에 맞추고 다시 눌러주세요."
                return
            }
            placementRequest = nil
            confirmBallReanchor(pose)
            return
        }
        guard placementRequest == nil else { return }
#if targetEnvironment(simulator)
        applySimulatorBallReanchor()
#else
        if trackingLimited {
            placementMessage = "트래킹이 정상일 때 다시 지정하세요."
            return
        }
        placementRequest = .reanchorBall
        placementMessage = "십자선을 볼 중심에 맞춘 뒤 다시 눌러 확정하세요."
#endif
    }

    /// 조준 중 실볼 재감지 — Step1과 같은 십자선 자동 감지를 다시 연다(버튼 한 번, 물리 유지).
    /// 조준 근접 하안에서도 AR이 실볼 앞에 어긋나 있어도 동작해야 함.
    func requestVisualBallRelock() {
        guard flowState == .complete, completedScan != nil, guidancePhaseActive else { return }
        guard placementRequest == nil else { return }
        if trackingLimited {
            placementMessage = "트래킹이 정상일 때 다시 맞추세요."
            return
        }
        resetVisualBallLock()
        guidanceRelockBoost = true
        visualBallLockStatus = .waitingForView
        placementMessage = "십자선을 실볼에 맞추세요."
        coverageHaptic.impactOccurred()
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
            case .reanchorBall:
                self.confirmBallReanchor(pose)
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

    /// 버튼 탭 순간 카메라 전방 raycast + sceneDepth 폴백. SwiftUI 지연 없이 좌표를 고정한다.
    private func immediateGroundPose() -> ScanPose? {
        guard let frame = session.currentFrame else { return nil }
        return centerGroundPose(frame: frame)
    }

    /// 링 오버레이와 동일한 월드 좌표. 합의 후보가 있을 때만 감지 좌표를 쓰고, 아니면 십자선.
    private func resolvedManualBallPlacementPose() -> ScanPose? {
        if let pending = pendingDetectedBall { return pending }
        return immediateGroundPose()
    }

    func centerGroundPose(frame: ARFrame) -> ScanPose? {
        let cam = frame.camera.transform
        let origin = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        var direction = SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)
        let length = simd_length(direction)
        guard length > 1e-5 else { return nil }
        direction /= length
        let estimated = ARRaycastQuery(
            origin: origin,
            direction: direction,
            allowing: .estimatedPlane,
            alignment: .any
        )
        if let hit = session.raycast(estimated).first {
            let t = hit.worldTransform.columns.3
            return ScanPose(
                worldX: Double(t.x),
                worldY: Double(t.y),
                worldZ: Double(t.z),
                timestamp: frame.timestamp
            )
        }
        let existing = ARRaycastQuery(
            origin: origin,
            direction: direction,
            allowing: .existingPlaneGeometry,
            alignment: .any
        )
        if let hit = session.raycast(existing).first {
            let t = hit.worldTransform.columns.3
            return ScanPose(
                worldX: Double(t.x),
                worldY: Double(t.y),
                worldZ: Double(t.z),
                timestamp: frame.timestamp
            )
        }
        if let world = ScanCoverageTracker.unprojectCenterGround(frame: frame) {
            return ScanPose(
                worldX: Double(world.x),
                worldY: Double(world.y),
                worldZ: Double(world.z),
                timestamp: frame.timestamp
            )
        }
        return nil
    }

    /// 홀 지정까지 끝난 뒤 높이맵 처리. 기본은 홀에서 바로 계산(드리프트 0).
    private func processCompletedScan(
        ballAnchor: ScanPose,
        holeAnchor: ScanPose,
        cameraStartPose: ScanPose,
        requireReturnToBall: Bool
    ) {
        processingGeneration += 1
        let generation = processingGeneration
        flowState = .processing

        // UI에 쓰로틀된 정점 수를 최종값으로 맞춤
        meshVertexCount = latestMeshes.values.reduce(0) { $0 + $1.count }

        let pathMode = self.pathMode
        /// 둘 다 홀에서 바로 계산. 드리프트 보정은 볼 복귀 카메라가 있을 때만.
        let driftCorrected = requireReturnToBall
        let fieldMode = ScanFieldSettings.fieldMode
        let corridorMargins = PuttScanCorridor.margins(for: fieldMode)
        let lidarProfile = self.lidarProfile
        let behindBallStats = BehindBallSweepGate.Stats.empty
        let walkStats = self.walkCorridorStatsSnapshot

#if targetEnvironment(simulator)
        let returnCamera: ScanPose
        if requireReturnToBall {
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
                    terrainTransform: transform,
                    terrainHoleAnchor: holeAnchor,
                    referenceMethod: Self.referenceMethod,
                    ballPlacementTrackingOK: ballOK,
                    holePlacementTrackingOK: holeOK,
                    driftCorrected: driftCorrected,
                    pathMode: pathMode,
                    fieldMode: fieldMode,
                    surfaceSource: surfaceSource,
                    surfaceVertexCount: surfaceVertexCount,
                    lidarProfile: lidarProfile,
                    behindBallSweepStats: behindBallStats,
                    walkCorridorStats: walkStats
                )
                await MainActor.run {
                    guard generation == self.processingGeneration else { return }
                    self.stopLiDARReconstructionKeepingWorld()
                    self.resetCoverageState()
                    self.latestMeshes.removeAll()
                    self.completedScan = scan
                    self.needsBallReanchor = pathMode.requiresBallReanchor
                    self.resetVisualBallLock()
#if targetEnvironment(simulator)
                    self.needsBallReanchor = false
                    self.visualBallLockStatus = .aligned
#else
                    self.visualBallLockStatus = .searching
#endif
                    self.guidancePhaseActive = true
                    self.guidanceTrackingEvents.removeAll()
                    self.guidanceTrackingOK = !self.trackingLimited
                    self.placementMessage = String(
                        format: "경로 계산 완료 · %.2fm · %@ · 실볼을 비추면 AR를 맞춤",
                        holeDistance,
                        pathMode.label
                    )
                    self.flowState = .complete
                }
            } catch {
                await MainActor.run {
                    guard generation == self.processingGeneration else { return }
                    self.stopLiDARReconstructionKeepingWorld()
                    self.resetCoverageState()
                    if let terrainError = error as? TerrainPipelineError {
                        self.fail(L10n.terrainError(terrainError))
                    } else {
                        self.fail(error.localizedDescription)
                    }
                }
            }
        }
#else
        let returnCamera: ScanPose
        if requireReturnToBall {
            guard let pose = currentCameraPose() else {
                fail(L10n.failNoReturnPose)
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
        let coverageSnapshot = self.coverageSnapshot

        Task.detached(priority: .userInitiated) {
            let fusedVertices = await coverage.fusedGroundVerticesAsync(
                ball: ballAnchor,
                hole: holeAnchor,
                margins: corridorMargins
            )
            let vertices: [ScanVertex]
            let surfaceSource: String
            var rawMeshCount = 0
            if fusedVertices.count >= 100 {
                vertices = fusedVertices
                surfaceSource = "temporal_scene_depth"
            } else {
                let rawMeshVertices = Self.filterMeshVerticesForTerrain(
                    meshSnapshot.values.flatMap { $0 },
                    ball: ballAnchor,
                    hole: holeAnchor,
                    margins: corridorMargins
                )
                rawMeshCount = rawMeshVertices.count
                (vertices, surfaceSource) = Self.selectTerrainVertices(
                    fused: fusedVertices,
                    rawMesh: rawMeshVertices,
                    coverage: coverageSnapshot,
                    ball: ballAnchor,
                    hole: holeAnchor,
                    margins: corridorMargins
                )
            }
            let usesFusedDepth = surfaceSource.hasPrefix("temporal_scene_depth")
            let surfaceVertexCount = vertices.count
            let meshCountForMessage = rawMeshCount

            await MainActor.run {
                guard generation == self.processingGeneration else { return }
                self.placementMessage = usesFusedDepth
                    ? "다중 프레임 깊이 융합 \(fusedVertices.count.formatted())점 처리 중…"
                    : "깊이 융합 관측 부족 · AR 메시 \(meshCountForMessage.formatted())점 처리 중…"
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
                    terrainTransform: transform,
                    terrainHoleAnchor: holeAnchor,
                    referenceMethod: Self.referenceMethod,
                    ballPlacementTrackingOK: ballOK,
                    holePlacementTrackingOK: holeOK,
                    driftCorrected: driftCorrected,
                    pathMode: pathMode,
                    fieldMode: fieldMode,
                    surfaceSource: surfaceSource,
                    surfaceVertexCount: surfaceVertexCount,
                    lidarProfile: lidarProfile,
                    behindBallSweepStats: behindBallStats,
                    walkCorridorStats: walkStats
                )
                await MainActor.run {
                    guard generation == self.processingGeneration else { return }
                    self.stopLiDARReconstructionKeepingWorld()
                    self.resetCoverageState()
                    self.latestMeshes.removeAll()
                    self.completedScan = scan
                    self.needsBallReanchor = pathMode.requiresBallReanchor
                    self.resetVisualBallLock()
#if targetEnvironment(simulator)
                    self.needsBallReanchor = false
                    self.visualBallLockStatus = .aligned
#else
                    self.visualBallLockStatus = .searching
#endif
                    self.guidancePhaseActive = true
                    self.guidanceTrackingEvents.removeAll()
                    self.guidanceTrackingOK = !self.trackingLimited
                    self.placementMessage = String(
                        format: "경로 계산 완료 · %.2fm · %@ · 실볼을 비추면 AR를 맞춤",
                        holeDistance,
                        pathMode.label
                    )
                    self.flowState = .complete
                }
            } catch {
                await MainActor.run {
                    guard generation == self.processingGeneration else { return }
                    self.stopLiDARReconstructionKeepingWorld()
                    self.resetCoverageState()
                    if let terrainError = error as? TerrainPipelineError {
                        self.fail(L10n.terrainError(terrainError))
                    } else {
                        self.fail(error.localizedDescription)
                    }
                }
            }
        }
#endif
    }

    /// 메시 폴백용: 발·깃대·솟은 blob 제거 + 볼-홀 복도 밖 대량 정점 축소.
    private static func filterMeshVerticesForTerrain(
        _ vertices: [ScanVertex],
        ball: ScanPose,
        hole: ScanPose,
        margins: ScanCorridorMargins
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
        for (index, vertex) in vertices.enumerated() {
            if reject[index] { continue }
            let inside = Self.isNearPuttCorridor(
                x: vertex.worldX,
                z: vertex.worldZ,
                ball: ball,
                hole: hole,
                lateralMargin: margins.lateralHalfWidth,
                ballEndMargin: margins.ballEndMargin,
                pastHoleMargin: margins.pastHoleMargin
            )
            if inside {
                kept.append(vertex)
            }
            if kept.count >= 80_000 { break }
        }
        return kept
    }

    /// 바둑판(커버리지) 표시와 지형 파이프라인 요건이 다르다. 융합·메시가 비면 관측 셀 중심으로 폴백.
    private static func selectTerrainVertices(
        fused: [ScanVertex],
        rawMesh: [ScanVertex],
        coverage: ScanCoverageSnapshot,
        ball: ScanPose,
        hole: ScanPose,
        margins: ScanCorridorMargins
    ) -> (vertices: [ScanVertex], source: String) {
        let coverageVerts = coverageSnapshotVertices(
            coverage,
            ball: ball,
            hole: hole,
            margins: margins
        )
        if fused.count >= 100 {
            return (fused, "temporal_scene_depth")
        }
        if !fused.isEmpty, fused.count >= rawMesh.count {
            return (fused, "temporal_scene_depth")
        }
        if !rawMesh.isEmpty {
            return (rawMesh, "arkit_mesh_fallback")
        }
        if !fused.isEmpty {
            return (fused, "temporal_scene_depth_partial")
        }
        if coverageVerts.count >= CoverageDisplayLock.minCellsToPlant {
            return (coverageVerts, "coverage_cell_fallback")
        }
        return ([], "none")
    }

    private static func coverageSnapshotVertices(
        _ snapshot: ScanCoverageSnapshot,
        ball: ScanPose,
        hole: ScanPose,
        margins: ScanCorridorMargins
    ) -> [ScanVertex] {
        var output: [ScanVertex] = []
        output.reserveCapacity(snapshot.cellHeights.count)
        for (key, height) in snapshot.cellHeights {
            let center = CoverageDisplayLock.cellCenterXZ(key)
            guard isNearPuttCorridor(
                x: Double(center.x),
                z: Double(center.y),
                ball: ball,
                hole: hole,
                lateralMargin: margins.lateralHalfWidth,
                ballEndMargin: margins.ballEndMargin,
                pastHoleMargin: margins.pastHoleMargin
            ) else { continue }
            output.append(
                ScanVertex(
                    worldX: Double(center.x),
                    worldY: Double(height),
                    worldZ: Double(center.y),
                    timestamp: 0
                )
            )
        }
        return output
    }

    private static func isNearPuttCorridor(
        x: Double,
        z: Double,
        ball: ScanPose,
        hole: ScanPose,
        lateralMargin: Double = PuttScanCorridor.tuningMargins.lateralHalfWidth,
        ballEndMargin: Double = PuttScanCorridor.tuningMargins.ballEndMargin,
        pastHoleMargin: Double = PuttScanCorridor.tuningMargins.pastHoleMargin
    ) -> Bool {
        let dx = hole.worldX - ball.worldX
        let dz = hole.worldZ - ball.worldZ
        let length = hypot(dx, dz)
        guard length > 1e-6 else {
            return hypot(x - ball.worldX, z - ball.worldZ)
                <= lateralMargin + max(ballEndMargin, pastHoleMargin)
        }
        let ux = dx / length
        let uz = dz / length
        let px = x - ball.worldX
        let pz = z - ball.worldZ
        let along = px * ux + pz * uz
        let lateral = abs(px * (-uz) + pz * ux)
        return along >= -ballEndMargin
            && along <= length + pastHoleMargin
            && lateral <= lateralMargin
    }

    func reset() {
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        processingGeneration += 1
        ballAnchor = nil
        holeAnchor = nil
        cameraStartPose = nil
        cameraReturnPose = nil
        placementRequest = nil
        placementMessage = nil
        latestMeshes.removeAll()
        completedScan = nil
        needsBallReanchor = false
        visualBallLockStatus = .idle
        resetVisualBallLock()
        pastHoleMeasuredMeters = 0
        sceneDepthReady = false
        meshVertexCount = 0
        meshCaptureEnabled = false
        meshCaptureBurstActive = false
        guidancePhaseActive = false
        guidanceTrackingEvents.removeAll()
        guidanceTrackingOK = true
        resetCoverageState()
        coverageDisplayEpoch &+= 1
        flowState = .idle
        lidarTwistGuidance = nil
        walkCorridorStatsSnapshot = .empty
        lastWalkTwistInBandSample = 0
        trackingLimited = false
        trackingDescription = "대기 중"
        // LiDAR 끄고, idle에서 다시 워밍업
        stopLiDARReconstructionKeepingWorld()
        ensureIdleLiDARPipelineRunning()
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
        updatePastHoleCoverage(from: snapshot)

        let gained = snapshot.stableCellCount - lastCoverageHapticStableCount
        if gained >= 8 {
            coverageHaptic.impactOccurred()
            lastCoverageHapticStableCount = snapshot.stableCellCount
        }
    }

    private func updatePastHoleCoverage(from snapshot: ScanCoverageSnapshot) {
        guard let ball = ballAnchor, let hole = holeAnchor else {
            if pastHoleMeasuredMeters != 0 { pastHoleMeasuredMeters = 0 }
            return
        }
        let dx = hole.worldX - ball.worldX
        let dz = hole.worldZ - ball.worldZ
        let length = hypot(dx, dz)
        guard length > 1e-6 else { return }
        let ux = dx / length
        let uz = dz / length
        let cellSize = Double(ScanCoverage.cellSizeMeters)
        var maxAlong = 0.0
        for key in snapshot.stableKeys.union(snapshot.tentativeKeys) {
            let ix = Int32(truncatingIfNeeded: key >> 32)
            let iz = Int32(bitPattern: UInt32(truncatingIfNeeded: key))
            let x = (Double(ix) + 0.5) * cellSize
            let z = (Double(iz) + 0.5) * cellSize
            let along = (x - ball.worldX) * ux + (z - ball.worldZ) * uz
            if along > maxAlong { maxAlong = along }
        }
        let past = max(0, min(maxAlong - length, PuttScanCorridor.pastHoleMargin))
        if abs(past - pastHoleMeasuredMeters) >= 0.05 {
            pastHoleMeasuredMeters = past
        }
    }

    func pauseARSession() {
        session.pause()
    }

    func resumeARSession() {
        switch flowState {
        case .failed:
            break
        default:
            // 이미 프레임이 오면 session.run 재호출을 피한다(월드 드리프트 방지).
            guard session.currentFrame == nil else { return }
            session.run(Self.makeScanConfiguration(reusing: session), options: [])
            scanConfigActive = true
        }
    }

    private var isCoverageActiveState: Bool {
        switch flowState {
        case .placingBall, .walkingToHole, .placingHole, .processing:
            return true
        case .complete:
            return needsBallReanchor
        default:
            return false
        }
    }

    /// ARMeshAnchor 정점 수집 — 스캔 중 + idle 워밍업(시작 시 버퍼가 비지 않게).
    private var isMeshCaptureState: Bool {
        meshCaptureEnabled && (isCoverageActiveState || meshWarmupActive)
    }

    /// 메시 수집만 멈춘다. 여기서 session.run으로 구성을 바꾸면 월드가 밀려
    /// 격자가 카메라 밖으로 나간다.
    private func stopLiDARReconstructionKeepingWorld() {
        meshCaptureEnabled = false
        if let frame = session.currentFrame {
            for anchor in frame.anchors where anchor is ARMeshAnchor {
                session.remove(anchor: anchor)
            }
        }
        scanConfigActive = true
    }

    // MARK: - Placement confirms

    private func confirmBallAnchor(_ pose: ScanPose) {
        guard flowState == .placingBall else { return }
        ballAnchor = pose
        ballDetectionPreview = nil
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
        coverageTracker.setPhase(.walkCorridor)
        coverageTracker.resetWalkCorridorAccumulator()
        coverageTracker.resetBehindBallAccumulator()
        walkCorridorStatsSnapshot = .empty
        // 별도 「볼 뒤 대기」 STEP 없음 — 걷기부터 항상 사선 스캔.
        flowState = .walkingToHole
        // 지정 전 십자선 임시 plant → 확정 볼 원점으로 흰 격자 재심기.
        coverageDisplayEpoch &+= 1
        placementMessage = nil
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
        guard let cameraStartPose else {
            fail(L10n.failNoCameraPose)
            return
        }
        // 볼홀·볼홀볼 모두 홀 지정 직후 경로 계산. 볼홀볼만 이후 실볼 재지정.
        processCompletedScan(
            ballAnchor: ball,
            holeAnchor: pose,
            cameraStartPose: cameraStartPose,
            requireReturnToBall: false
        )
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
                terrainTransform: scan.terrainTransform,
                terrainHoleAnchor: scan.terrainHoleAnchor,
                referenceMethod: Self.referenceMethod,
                ballPlacementTrackingOK: scan.ballPlacementTrackingOK,
                holePlacementTrackingOK: !trackingLimited,
                driftCorrected: scan.driftCorrected,
                pathMode: scan.pathMode,
                fieldMode: scan.fieldMode,
                surfaceSource: scan.surfaceSource,
                surfaceVertexCount: scan.surfaceVertexCount,
                lidarProfile: scan.lidarProfile,
                behindBallSweepStats: scan.behindBallSweepStats,
                walkCorridorStats: scan.walkCorridorStats
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

    private func confirmBallReanchor(_ pose: ScanPose) {
        guard flowState == .complete, let scan = completedScan else { return }
        let distance = hypot(
            scan.holeAnchor.worldX - pose.worldX,
            scan.holeAnchor.worldZ - pose.worldZ
        )
        guard distance >= Self.minimumHoleDistance else {
            placementMessage = "볼과 홀이 너무 가깝습니다. 볼 재지정 실패."
            return
        }
        do {
            let transform = try ScanCoordinateTransform(ball: pose, hole: scan.holeAnchor)
            completedScan = CompletedScan(
                id: scan.id,
                result: scan.result,
                trackingEvents: scan.trackingEvents,
                limitedTrackingRatio: scan.limitedTrackingRatio,
                startedAt: scan.startedAt,
                ballAnchor: pose,
                holeAnchor: scan.holeAnchor,
                cameraStartPose: scan.cameraStartPose,
                cameraReturnPose: scan.cameraReturnPose,
                holeDistance: distance,
                scanTransform: transform,
                terrainTransform: scan.terrainTransform,
                terrainHoleAnchor: scan.terrainHoleAnchor,
                referenceMethod: Self.referenceMethod,
                ballPlacementTrackingOK: !trackingLimited,
                holePlacementTrackingOK: scan.holePlacementTrackingOK,
                driftCorrected: scan.driftCorrected,
                pathMode: scan.pathMode,
                fieldMode: scan.fieldMode,
                surfaceSource: scan.surfaceSource,
                surfaceVertexCount: scan.surfaceVertexCount,
                lidarProfile: scan.lidarProfile,
                behindBallSweepStats: scan.behindBallSweepStats,
                walkCorridorStats: scan.walkCorridorStats
            )
            ballAnchor = pose
            needsBallReanchor = false
            guidanceLiveBallPose = nil
            visualBallLockStatus = .locked(offsetMeters: hypot(
                pose.worldX - scan.ballAnchor.worldX,
                pose.worldZ - scan.ballAnchor.worldZ
            ))
            markVisualLock(at: pose)
            resetCoverageState()
            latestMeshes.removeAll()
            guidanceTrackingEvents.removeAll()
            guidanceTrackingOK = true
            placementMessage = String(format: "볼 재지정 완료 · %.2fm", distance)
            trackingDescription = "볼 재지정 완료"
        } catch {
            placementMessage = "볼 재지정 실패: \(error.localizedDescription)"
        }
    }

    private func resetVisualBallLock() {
        visualLockConsensus.reset()
        visualLockProcessing = false
        lastVisualLockTime = 0
        pendingDetectedBall = nil
        ballDetectionPreview = nil
        guidanceLiveBallPose = nil
        guidanceDetectArmed = false
        guidanceRelockBoost = false
    }

    /// 조준: 볼 뒤/하안 도착 전에는 감지·링을 켜지 않음(돌아오는 길 오탐 링 방지).
    private var guidanceDetectArmed = false
    /// 「실볼 재감지」탭 후 — 하안·근접에서 AR이 어긋나도 물리 볼 기준으로 다시 잡게 함.
    private var guidanceRelockBoost = false

    /// 볼 배치·조준 감지 링. 확정되면 nil → UI 사라짐.
    var ballRingWorldPose: ScanPose? {
        if flowState == .placingBall {
            return pendingDetectedBall ?? ballDetectionPreview
        }
        // 조준: 볼 위치 도착(armed) 후에만 링. 안정 합의 후 settled → nil.
        if flowState == .complete, guidancePhaseActive, !visualBallLockStatus.isSettled {
            guard guidanceDetectArmed else { return nil }
            return pendingDetectedBall ?? ballDetectionPreview
        }
        return nil
    }

    private var isVisualBallHunting: Bool {
        if flowState == .placingBall { return true }
        // 조준: 링이 몇 프레임 안정 → AR 이동 후 settled 되면 종료.
        if flowState == .complete, guidancePhaseActive, !visualBallLockStatus.isSettled {
            return true
        }
        return false
    }

    private var showsHoleCupPlacementRing: Bool {
        !hidesHoleCupRingOverlay
            && (flowState == .placingHole || placementRequest == .reanchorHole)
    }

    /// Screen-space ball ring for UIKit overlay (no `@Published` — safe from DisplayLink).
    func projectedBallGroundRing(frame: ARFrame?, viewport: CGSize) -> [CGPoint] {
        guard let pose = ballRingWorldPose, let frame else { return [] }
        return BallGroundRingProjector.screenPoints(
            worldX: pose.worldX,
            worldY: pose.worldY,
            worldZ: pose.worldZ,
            camera: frame.camera,
            viewport: viewport,
            orientation: Self.interfaceOrientation()
        ) ?? []
    }

    /// Screen-space hole-cup ring for UIKit overlay (no `@Published` — safe from DisplayLink).
    func projectedHoleGroundRing(frame: ARFrame?, viewport: CGSize) -> [CGPoint] {
        guard showsHoleCupPlacementRing, let frame else { return [] }
        guard let pose = centerGroundPose(frame: frame) else { return [] }
        return GroundCircleProjector.screenPoints(
            worldX: pose.worldX,
            worldY: pose.worldY,
            worldZ: pose.worldZ,
            radiusMeters: Double(ARReferenceMarkers.holeRadius),
            camera: frame.camera,
            viewport: viewport,
            orientation: Self.interfaceOrientation()
        ) ?? []
    }

    private func updateBallDetectionPreview(_ contact: GolfBallWorldContact, timestamp: TimeInterval) {
        guard contact.confidence >= 0.50 else { return }
        let pose = ScanPose(
            worldX: contact.worldX,
            worldY: contact.worldY,
            worldZ: contact.worldZ,
            timestamp: timestamp
        )
        guard let previous = ballDetectionPreview else {
            ballDetectionPreview = pose
            return
        }
        let jump = hypot(previous.worldX - pose.worldX, previous.worldZ - pose.worldZ)
        // 마커→실볼 기어감을 없앤다. 1.5cm 미만만 소량 보정.
        if jump >= 0.015 {
            ballDetectionPreview = pose
            return
        }
        let alpha = ballPreviewSmoothing
        ballDetectionPreview = ScanPose(
            worldX: previous.worldX * (1 - alpha) + pose.worldX * alpha,
            worldY: previous.worldY * (1 - alpha) + pose.worldY * alpha,
            worldZ: previous.worldZ * (1 - alpha) + pose.worldZ * alpha,
            timestamp: timestamp
        )
    }

    private func markVisualLock(at pose: ScanPose) {
        visualLockConsensus.locked = true
        visualLockConsensus.lastAppliedX = pose.worldX
        visualLockConsensus.lastAppliedZ = pose.worldZ
        visualLockConsensus.recent = [
            GolfBallLockConsensus.Sample(x: pose.worldX, y: pose.worldY, z: pose.worldZ)
        ]
        freezeGuidanceWorldAnchor()
    }

    /// 조준 오버레이는 스캔 볼 월드 좌표에 고정. 실볼 미세 보정으로 앵커를 옮기면 하안에서 AR이 흐른다.
    private func freezeGuidanceWorldAnchor() {
        guidanceLiveBallPose = nil
    }

    /// 조준선 근접 하안 — 볼이 화면에서 커지고 카메라가 낮다.
    /// AR 표시 볼이 아니라 Step1 물리 볼 기준(오지정 AR이 앞에 있어도 하안에서 재감지 가능).
    private func isCloseAimGuidance(cameraToWorld: simd_float4x4) -> Bool {
        guard let ball = completedScan?.physicsStartPose ?? completedScan?.ballAnchor else {
            return false
        }
        let cam = cameraToWorld.columns.3
        let dx = Double(cam.x) - ball.worldX
        let dy = Double(cam.y) - ball.worldY
        let dz = Double(cam.z) - ball.worldZ
        let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
        // 쪼그려 흰 조준선에 맞출 때 폰이 볼에 더 가깝고 낮음.
        return dist < 1.50 && dy < 0.72
    }

    /// 조준 실볼 확정 자세.
    /// - 볼 뒤 스탠스(가깝게): 서서 흰 조준선에 맞출 때
    /// - 조준 근접 하안: 쪼그려 볼·흰 선을 맞출 때
    /// - 재감지 탭 후: 물리 볼 근처면 하안·스탠스 완화(AR이 앞에 있어도 됨)
    private func isGuidanceConfirmStance(cameraToWorld: simd_float4x4) -> Bool {
        if isCloseAimGuidance(cameraToWorld: cameraToWorld) {
            return true
        }
        guard let scan = completedScan else { return false }
        let ball = scan.physicsStartPose
        let cam = cameraToWorld.columns.3
        let toCamX = Double(cam.x) - ball.worldX
        let toCamY = Double(cam.y) - ball.worldY
        let toCamZ = Double(cam.z) - ball.worldZ
        let dist = (toCamX * toCamX + toCamY * toCamY + toCamZ * toCamZ).squareRoot()

        // 재감지: 물리 볼 1.5m 안이면 바로 감지 재개(하안 포함).
        if guidanceRelockBoost, dist <= 1.50 {
            return true
        }

        guard dist <= 1.15 else { return false }
        let hole = scan.terrainHoleAnchor
        let fx = hole.worldX - ball.worldX
        let fz = hole.worldZ - ball.worldZ
        let flen = hypot(fx, fz)
        guard flen > 0.05 else { return false }
        let along = (toCamX * fx + toCamZ * fz) / flen
        return along < -0.12
    }

    private func processVisualBallLock(frame: ARFrame) {
        let placing = flowState == .placingBall
        let guiding = flowState == .complete && guidancePhaseActive
        let hunting = isVisualBallHunting
        guard hunting else { return }
        guard placing || guiding, placementRequest == nil else { return }
#if targetEnvironment(simulator)
        return
#else
        let now = frame.timestamp
        let interval = GolfBallVisualLockSession.placingProcessInterval
        guard now - lastVisualLockTime >= interval else { return }
        guard !visualLockProcessing else { return }

        // 조준: 볼 뒤/하안 도착 전에는 감지·링 전부 끔(돌아오는 길 여기저기 링 방지).
        if guiding {
            let armed = isGuidanceConfirmStance(cameraToWorld: frame.camera.transform)
            if !armed {
                lastVisualLockTime = now
                if guidanceDetectArmed
                    || ballDetectionPreview != nil
                    || pendingDetectedBall != nil
                    || !visualLockConsensus.recent.isEmpty
                    || visualBallLockStatus != .waitingForView {
                    guidanceDetectArmed = false
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard self.flowState == .complete, self.guidancePhaseActive,
                              !self.visualBallLockStatus.isSettled else { return }
                        self.guidanceDetectArmed = false
                        self.ballDetectionPreview = nil
                        self.pendingDetectedBall = nil
                        if !self.visualLockConsensus.recent.isEmpty {
                            self.visualLockConsensus.recent.removeAll(keepingCapacity: true)
                        }
                        if self.visualBallLockStatus != .waitingForView {
                            self.visualBallLockStatus = .waitingForView
                        }
                    }
                } else {
                    guidanceDetectArmed = false
                }
                return
            }
            guidanceDetectArmed = true
        } else {
            guidanceDetectArmed = false
        }

        // Step1·조준 모두 십자선 탐색. 조준만 Step1 물리 볼을 기준점으로 씀.
        let physicsRef: ScanPose? = guiding
            ? (completedScan?.physicsStartPose ?? completedScan?.ballAnchor)
            : nil
        let viewport = UIScreen.main.bounds.size
        let orientation = Self.interfaceOrientation()
        guard let snapshot = GolfBallVisualLockSession.snapshot(
            frame: frame,
            currentBall: nil,
            viewport: viewport,
            orientation: orientation,
            referenceBall: physicsRef,
            forceReticleSearch: true
        ) else {
            lastVisualLockTime = now
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.visualLockConsensus.noteMiss()
                if !self.visualBallLockStatus.isSettled, self.visualBallLockStatus != .waitingForView {
                    self.visualBallLockStatus = .waitingForView
                    if self.flowState == .placingBall {
                        self.placementMessage = "십자선을 볼 중심에 맞추세요."
                    } else if self.flowState == .complete, self.guidancePhaseActive {
                        self.placementMessage = "십자선을 실볼에 맞추세요."
                    }
                }
            }
            return
        }
        lastVisualLockTime = now
        visualLockProcessing = true
        let scanID = completedScan?.id
        visualLockQueue.async { [weak self] in
            let contact = GolfBallVisualLockSession.analyze(snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.visualLockProcessing = false
                let stillPlacing = self.flowState == .placingBall
                let stillGuiding = self.flowState == .complete && self.guidancePhaseActive
                let stillHunting = self.isVisualBallHunting
                guard stillPlacing || stillGuiding, self.placementRequest == nil else { return }
                if stillGuiding, self.completedScan?.id != scanID { return }
                guard let contact else {
                    self.visualLockConsensus.noteMiss()
                    if stillHunting {
                        if self.visualLockConsensus.recent.isEmpty {
                            self.ballDetectionPreview = nil
                        }
                        if self.visualLockConsensus.recent.count < 2 {
                            self.pendingDetectedBall = nil
                            if self.visualBallLockStatus == .candidate {
                                self.visualBallLockStatus = .searching
                            }
                        }
                        if !self.visualBallLockStatus.isSettled,
                           self.visualBallLockStatus != .searching,
                           self.visualBallLockStatus != .candidate {
                            self.visualBallLockStatus = .searching
                        }
                    }
                    return
                }
                if stillHunting {
                    self.updateBallDetectionPreview(contact, timestamp: now)
                    if !self.visualBallLockStatus.isSettled,
                       self.visualBallLockStatus == .waitingForView {
                        self.visualBallLockStatus = .searching
                    }
                }

                // 조준: Step1 물리 근처에서 링 안정 시 확정(이미 볼 뒤/하안에서만 감지 진입).
                let physicsRef = self.completedScan?.physicsStartPose ?? self.completedScan?.ballAnchor
                if stillGuiding, stillHunting, !self.visualBallLockStatus.isSettled {
                    guard let physicsRef else { return }
                    let fromPhysics = hypot(
                        contact.worldX - physicsRef.worldX,
                        contact.worldZ - physicsRef.worldZ
                    )
                    if fromPhysics > GolfBallVisualLock.guidanceConfirmNearPhysicsMeters {
                        if !self.visualLockConsensus.recent.isEmpty {
                            self.visualLockConsensus.recent.removeAll(keepingCapacity: true)
                        }
                        self.ballDetectionPreview = nil
                        self.pendingDetectedBall = nil
                        if self.visualBallLockStatus == .candidate {
                            self.visualBallLockStatus = .searching
                        }
                        return
                    }
                }

                let action = self.visualLockConsensus.ingest(
                    contact: contact,
                    currentBallX: stillGuiding ? self.completedScan?.ballAnchor.worldX : nil,
                    currentBallZ: stillGuiding ? self.completedScan?.ballAnchor.worldZ : nil,
                    physicsBallX: stillGuiding ? physicsRef?.worldX : nil,
                    physicsBallZ: stillGuiding ? physicsRef?.worldZ : nil,
                    // Step1과 동일: 3프레임 같은 자리 합의 후 확정.
                    minAgree: GolfBallLockConsensus.minAgree,
                    // 조준도 물리(Step1) 근접을 강제 — 멀리 오탐으로 확정 금지.
                    enforceProximityLimits: true
                )
                switch action {
                case .none:
                    if stillHunting, !self.visualBallLockStatus.isSettled {
                        // 조준·지정 모두 첫 감지에서 「위치 조정 중」으로 넘어가 피드백을 빨리.
                        if self.visualLockConsensus.recent.count >= 1 {
                            self.visualBallLockStatus = .candidate
                        } else if self.visualBallLockStatus != .searching,
                                  self.visualBallLockStatus != .candidate {
                            self.visualBallLockStatus = .searching
                        }
                    }
                case .confirmAligned:
                    self.needsBallReanchor = false
                    self.guidanceRelockBoost = false
                    if stillHunting, !self.visualBallLockStatus.isSettled {
                        self.visualBallLockStatus = .aligned
                        self.ballDetectionPreview = nil
                        self.pendingDetectedBall = nil
                        if stillGuiding {
                            self.placementMessage = "실볼 확인 · AR·실볼 일치"
                        }
                    }
                    self.freezeGuidanceWorldAnchor()
                case .apply(let fix):
                    if stillPlacing {
                        self.offerDetectedBallCandidate(fix, timestamp: now)
                    } else if stillGuiding, stillHunting, let live = self.completedScan {
                        // 링과 같은 0.50. 합의는 이미 locked라 적용 실패 시 롤백.
                        if fix.confidence >= 0.50 {
                            self.applyVisualBallLock(fix, scan: live, timestamp: now)
                            self.guidanceRelockBoost = false
                        }
                        if !self.visualBallLockStatus.isSettled {
                            self.visualLockConsensus.locked = false
                        }
                    }
                }
            }
        }
#endif
    }

    /// 감지는 후보만 제시. 지정은 `requestBallPlacement`에서 골퍼 확인 후.
    private func offerDetectedBallCandidate(
        _ contact: GolfBallWorldContact,
        timestamp: TimeInterval
    ) {
        guard flowState == .placingBall else { return }
        guard contact.confidence >= 0.55 else { return }
        let pose = ScanPose(
            worldX: contact.worldX,
            worldY: contact.worldY,
            worldZ: contact.worldZ,
            timestamp: timestamp
        )
        if let previous = pendingDetectedBall {
            let jump = hypot(previous.worldX - pose.worldX, previous.worldZ - pose.worldZ)
            // 25cm 이상은 다른 물체. 그 안은 같은 볼의 원점 보정으로 보고 스냅한다.
            guard jump < 0.25 else { return }
        }
        pendingDetectedBall = pose
        ballDetectionPreview = pose
        visualBallLockStatus = .candidate
        placementMessage = "볼 후보를 찾았습니다. 맞으면 확인, 틀리면 십자선으로 직접 지정하세요."
        coverageHaptic.impactOccurred()
    }

    /// 조준 복귀: AR 표시 볼을 실볼 감지 링에 맞춤. 물리 원점(terrain)은 유지. 1회 후 감지 종료.
    private func applyVisualBallLock(
        _ contact: GolfBallWorldContact,
        scan: CompletedScan,
        timestamp: TimeInterval
    ) {
        let pose = ScanPose(
            worldX: contact.worldX,
            worldY: contact.worldY,
            worldZ: contact.worldZ,
            timestamp: timestamp
        )
        let holeDistance = hypot(
            scan.holeAnchor.worldX - pose.worldX,
            scan.holeAnchor.worldZ - pose.worldZ
        )
        guard holeDistance >= Self.minimumHoleDistance else { return }
        do {
            let transform = try ScanCoordinateTransform(ball: pose, hole: scan.holeAnchor)
            let offset = hypot(
                pose.worldX - scan.ballAnchor.worldX,
                pose.worldZ - scan.ballAnchor.worldZ
            )
            completedScan = CompletedScan(
                id: scan.id,
                result: scan.result,
                trackingEvents: scan.trackingEvents,
                limitedTrackingRatio: scan.limitedTrackingRatio,
                startedAt: scan.startedAt,
                ballAnchor: pose,
                holeAnchor: scan.holeAnchor,
                cameraStartPose: scan.cameraStartPose,
                cameraReturnPose: scan.cameraReturnPose,
                holeDistance: holeDistance,
                scanTransform: transform,
                terrainTransform: scan.terrainTransform,
                terrainHoleAnchor: scan.terrainHoleAnchor,
                referenceMethod: Self.referenceMethod,
                ballPlacementTrackingOK: !trackingLimited,
                holePlacementTrackingOK: scan.holePlacementTrackingOK,
                driftCorrected: scan.driftCorrected,
                pathMode: scan.pathMode,
                fieldMode: scan.fieldMode,
                surfaceSource: scan.surfaceSource,
                surfaceVertexCount: scan.surfaceVertexCount,
                lidarProfile: scan.lidarProfile,
                behindBallSweepStats: scan.behindBallSweepStats,
                walkCorridorStats: scan.walkCorridorStats
            )
            ballAnchor = pose
            needsBallReanchor = false
            visualBallLockStatus = .locked(offsetMeters: offset)
            ballDetectionPreview = nil
            pendingDetectedBall = nil
            markVisualLock(at: pose)
            freezeGuidanceWorldAnchor()
            placementMessage = String(
                format: "AR 볼 → 실볼 정렬 · %.0fmm",
                offset * 1000
            )
            coverageHaptic.impactOccurred()
        } catch {
            placementMessage = "실볼 정렬 실패"
        }
    }

#if targetEnvironment(simulator)
    private func applySimulatorBall() {
        let ball = ScanPose(worldX: 0, worldY: 0.3, worldZ: 0, timestamp: 0)
        ballAnchor = ball
        cameraStartPose = ScanPose(worldX: 0, worldY: 1.2, worldZ: 0, timestamp: 0)
        ballPlacementTrackingOK = true
        placementMessage = "시뮬레이터 볼 기준 (0, 0.3, 0)"
        coverageTracker.setPhase(.walkCorridor)
        coverageTracker.resetWalkCorridorAccumulator()
        flowState = .walkingToHole
    }

    private func applySimulatorHole() {
        let hole = ScanPose(worldX: 0, worldY: 0.33, worldZ: 3, timestamp: 10)
        holeAnchor = hole
        holePlacementTrackingOK = true
        placementMessage = "시뮬레이터 홀 기준 (0, 0.33, 3) · 거리 3.00m"
        guard let cameraStartPose, let ballAnchor else { return }
        processCompletedScan(
            ballAnchor: ballAnchor,
            holeAnchor: hole,
            cameraStartPose: cameraStartPose,
            requireReturnToBall: false
        )
    }

    private func applySimulatorHoleReanchor() {
        confirmHoleReanchor(ScanPose(worldX: 0, worldY: 0.33, worldZ: 3, timestamp: Date().timeIntervalSince1970))
    }

    private func applySimulatorBallReanchor() {
        confirmBallReanchor(ScanPose(worldX: 0.02, worldY: 0.3, worldZ: 0, timestamp: Date().timeIntervalSince1970))
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
        visualBallLockStatus = .idle
        resetVisualBallLock()
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

    // MARK: - LiDAR twist guidance

    private var showsLiDARTwistGuidance: Bool {
        switch flowState {
        case .placingBall, .walkingToHole, .placingHole, .processing:
            return true
        default:
            return false
        }
    }

    private func updateLiDARTwistGuidance(frame: ARFrame) {
        guard showsLiDARTwistGuidance else {
            if lidarTwistGuidance != nil { lidarTwistGuidance = nil }
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastTwistGuidanceUpdate >= 0.1 else { return }
        lastTwistGuidanceUpdate = now

        let orientation = Self.interfaceOrientation()
        let viewport = UIScreen.main.bounds.size
        var xs: [Double] = []
        if let ball = ballAnchor,
           let x = Self.normalizedScreenX(
            worldX: ball.worldX,
            worldY: ball.worldY,
            worldZ: ball.worldZ,
            frame: frame,
            orientation: orientation,
            viewport: viewport
        ) {
            xs.append(x)
        }
        if let hole = holeAnchor,
           let x = Self.normalizedScreenX(
            worldX: hole.worldX,
            worldY: hole.worldY,
            worldZ: hole.worldZ,
            frame: frame,
            orientation: orientation,
            viewport: viewport
           ) {
            xs.append(x)
        }
        let markerX = xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        let profile = lidarProfile
        let inBand = markerX.map { profile.isInTargetBand(normalizedX: $0) } ?? false
        let pitchDegreesRaw = Self.phonePitchDegrees(cameraTransform: frame.camera.transform)
        let pitchDegrees = pitchDegreesRaw.map { ($0 * 2).rounded() / 2 } // 0.5° 단위
        let pitchInBand = Self.isPhonePitchInScanBand(degrees: pitchDegrees)

        var walkProgress: Double?
        var walkDistance: Double?
        var walkRibbon: Int?
        var walkCanArrive: Bool?
        var walkStatus: String?
        if flowState == .walkingToHole {
            let stats = coverageTracker.latestWalkCorridorStats
            walkCorridorStatsSnapshot = stats
            if now - lastWalkTwistInBandSample >= 0.33 {
                lastWalkTwistInBandSample = now
                coverageTracker.applyWalkTwistInBand(inBand, frameTimestamp: frame.timestamp)
            }
            walkProgress = WalkCorridorGate.progress(stats: stats)
            walkDistance = stats.maxDistanceFromBall
            walkRibbon = stats.ribbonCells
            walkCanArrive = stats.qualityMet
            if stats.qualityMet {
                walkStatus = "참고 품질 OK"
            } else if stats.ribbonCells < WalkCorridorGate.requiredRibbonCells
                || stats.goodFrames < WalkCorridorGate.minimumGoodFrames {
                walkStatus = "라인 리본 더 채우면 좋음"
            } else {
                walkStatus = "스캔 중"
            }
        }

        let next = LiDARTwistGuidanceState(
            bandMinX: profile.targetScreenBandMinX,
            bandMaxX: profile.targetScreenBandMaxX,
            markerNormalizedX: markerX,
            inBand: inBand,
            actionText: profile.twistActionLabel(normalizedX: markerX),
            statusText: {
                if markerX != nil {
                    return inBand ? "화면 안 · OK" : "볼·홀을 화면 안으로"
                }
                return "볼·홀이 화면 밖"
            }(),
            pitchLookingAtGround: pitchInBand,
            pitchDegrees: pitchDegrees,
            pitchInBand: pitchInBand,
            walkProgress: walkProgress,
            walkDistanceMeters: walkDistance,
            walkRibbonCells: walkRibbon,
            walkCanArrive: walkCanArrive,
            walkStatusText: walkStatus
        )
        if lidarTwistGuidance != next {
            lidarTwistGuidance = next
        }
    }

    private static func interfaceOrientation() -> UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.interfaceOrientation ?? .portrait
    }

    private static func normalizedScreenX(
        worldX: Double,
        worldY: Double,
        worldZ: Double,
        frame: ARFrame,
        orientation: UIInterfaceOrientation,
        viewport: CGSize
    ) -> Double? {
        let world = SIMD3<Float>(Float(worldX), Float(worldY), Float(worldZ))
        let point = frame.camera.projectPoint(world, orientation: orientation, viewportSize: viewport)
        guard point.x.isFinite, point.y.isFinite, viewport.width > 1 else { return nil }
        let cam = frame.camera.transform.inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
        guard cam.z < -0.05 else { return nil }
        let x = Double(point.x / viewport.width)
        guard x >= -0.15, x <= 1.15 else { return nil }
        return min(max(x, 0), 1)
    }

    /// 사용자 각도: 0°=바닥 수평(카메라 직하), 90°=스크린 정면(카메라 수평).
    private static func phonePitchDegrees(cameraTransform: simd_float4x4) -> Double? {
        let look = SIMD3<Float>(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        )
        let length = simd_length(look)
        guard length > 1e-5 else { return nil }
        let down = SIMD3<Float>(0, -1, 0)
        let cosAngle = Double(simd_dot(look / length, down))
        let clamped = min(max(cosAngle, -1), 1)
        return acos(clamped) * 180 / .pi
    }

    private static func isPhonePitchInScanBand(cameraTransform: simd_float4x4) -> Bool {
        isPhonePitchInScanBand(degrees: phonePitchDegrees(cameraTransform: cameraTransform))
    }

    private static func isPhonePitchInScanBand(degrees: Double?) -> Bool {
        guard let degrees else { return false }
        return degrees >= ScanPhonePitchGuidance.bandMinDegrees
            && degrees <= ScanPhonePitchGuidance.bandMaxDegrees
    }
}

extension ARScanSessionController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let state = flowState
        if state == .idle, scanConfigActive {
            let meshCount = frame.anchors.lazy.filter { $0 is ARMeshAnchor }.count
            var initializing = false
            if case .limited(.initializing) = frame.camera.trackingState {
                initializing = true
            }
            if meshCount != warmupMeshAnchorCount || initializing != trackingInitializing {
                DispatchQueue.main.async {
                    self.warmupMeshAnchorCount = meshCount
                    self.trackingInitializing = initializing
                    if case .normal = frame.camera.trackingState {
                        self.trackingInitializing = false
                    }
                }
            }
        }
        updateLiDARTwistGuidance(frame: frame)

        let depthReady = frame.sceneDepth != nil
        if depthReady != sceneDepthReady {
            DispatchQueue.main.async {
                self.sceneDepthReady = depthReady
            }
        }

        // Polycam형 커버리지: 스캔 직후 유예 뒤에 depth 샘플링 (첫 LiDAR 가동과 겹치면 행업).
        // depth 복사만 세션 스레드, 역투영·융합은 tracker 큐 — RGB 볼감지와 병렬 가능.
        if isCoverageActiveState,
           meshCaptureEnabled,
           CACurrentMediaTime() >= heavyWorkAllowedAfter {
            let limited = trackingLimited
            let ball = self.ballAnchor
            let ballY = ball?.worldY
            let ballXZ = ball.map { SIMD2<Double>($0.worldX, $0.worldZ) }
            coverageTracker.process(
                frame: frame,
                trackingLimited: limited,
                phase: .walkCorridor,
                ball: ball,
                ballY: ballY,
                ballXZ: ballXZ,
                burst: true
            ) { [weak self] snapshot in
                guard let self, self.isCoverageActiveState else { return }
                self.applyCoverageSnapshot(snapshot)
                if self.flowState == .walkingToHole {
                    self.walkCorridorStatsSnapshot = self.coverageTracker.latestWalkCorridorStats
                }
            }
        }

        processVisualBallLock(frame: frame)
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
        let timestamp = session.currentFrame?.timestamp ?? 0
        let meshAnchorCount = session.currentFrame?.anchors.filter { $0 is ARMeshAnchor }.count ?? 0
        let initializing: Bool
        switch camera.trackingState {
        case .normal:
            description = "정상"
            limited = false
            initializing = false
        case .notAvailable:
            description = "사용 불가"
            limited = true
            initializing = false
        case .limited(let reason):
            limited = true
            switch reason {
            case .initializing:
                description = "제한됨: 초기화 중"
                initializing = true
            case .excessiveMotion:
                description = "제한됨: 움직임이 너무 빠름"
                initializing = false
            case .insufficientFeatures:
                description = "제한됨: 특징점 부족"
                initializing = false
            case .relocalizing:
                description = "제한됨: 위치 재탐색 중"
                initializing = false
            @unknown default:
                description = "제한됨"
                initializing = false
            }
        }
        DispatchQueue.main.async {
            self.trackingDescription = description
            self.trackingLimited = limited
            self.trackingInitializing = initializing
            if self.flowState == .idle {
                self.warmupMeshAnchorCount = meshAnchorCount
            }
            switch self.flowState {
            case .placingBall, .walkingToHole, .placingHole:
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
        let minInterval: TimeInterval
        if flowState == .placingBall {
            // 볼 지정 중에는 RGB 탐지가 세션 스레드를 써야 한다. 메시는 워밍업분 + 느린 보강만.
            minInterval = pendingMeshVertexCount >= Self.meshReadyVertexThreshold ? 0.55 : 0.16
        } else {
            minInterval = meshCaptureBurstActive ? 0.06 : 0.35
        }
        guard frameTimestamp - lastMeshCaptureTime >= minInterval else { return }
        lastMeshCaptureTime = frameTimestamp

        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }
        let camX = cameraTransform.map { Double($0.columns.3.x) }
        let camZ = cameraTransform.map { Double($0.columns.3.z) }
        let ballY = ballAnchor?.worldY

        // 지오메트리는 델리게이트 콜백 안에서만 유효 — 여기서 복사한 뒤 필터만 백그라운드.
        var copies: [(UUID, [GroundScanFilter.Point])] = []
        copies.reserveCapacity(meshAnchors.count)
        for meshAnchor in meshAnchors {
            let source = meshAnchor.geometry.vertices
            var points: [GroundScanFilter.Point] = []
            points.reserveCapacity(min(source.count, Self.maxVerticesPerAnchor))
            let step = max(1, source.count / Self.maxVerticesPerAnchor)
            let contents = source.buffer.contents()
            let offset = source.offset
            let stride = source.stride
            let transform = meshAnchor.transform
            for index in Swift.stride(from: 0, to: source.count, by: step) {
                let pointer = contents
                    .advanced(by: offset + stride * index)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                let local = pointer.pointee
                let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                points.append(
                    GroundScanFilter.Point(
                        worldX: Double(world.x),
                        worldY: Double(world.y),
                        worldZ: Double(world.z)
                    )
                )
            }
            copies.append((meshAnchor.identifier, points))
        }

        meshExtractionQueue.async { [weak self] in
            var snapshots: [(UUID, [ScanVertex])] = []
            for (identifier, copied) in copies {
                var points = copied
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
                snapshots.append((identifier, vertices))
            }
            guard !snapshots.isEmpty else { return }

            DispatchQueue.main.async {
                guard let self, self.isMeshCaptureState else { return }
                for (identifier, vertices) in snapshots {
                    self.latestMeshes[identifier] = vertices
                }
                self.pruneLatestMeshesIfNeeded(
                    cameraX: camX,
                    cameraZ: camZ
                )
                let totalCount = self.latestMeshes.values.reduce(0) { $0 + $1.count }
                self.pendingMeshVertexCount = totalCount
                let crossedReady = totalCount >= Self.meshReadyVertexThreshold
                    && self.meshVertexCount < Self.meshReadyVertexThreshold
                if crossedReady {
                    self.meshCaptureBurstActive = false
                }
                let publishInterval: TimeInterval = self.meshCaptureBurstActive ? 0.12 : 0.5
                let publishDelta = self.meshCaptureBurstActive ? 80 : 500
                if crossedReady
                    || frameTimestamp - self.lastMeshVertexPublishTime >= publishInterval
                    || abs(totalCount - self.meshVertexCount) >= publishDelta {
                    self.meshVertexCount = totalCount
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
