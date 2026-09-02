import Foundation
import PuttPhysicsKit
import SwiftUI

enum Gate55ComputeMode: String, CaseIterable, Identifiable {
    case recommend
    case forward

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recommend: return "추천(모드2)"
        case .forward: return "순검증(모드1)"
        }
    }
}

@MainActor
final class Gate55GuidanceModel: ObservableObject {
    static let greenSpeedKey = "perf.greenSpeed"
    static let greenSpeedPresets: [Double] = [2.5, 2.8, 3.0, 3.3]

    @Published var greenSpeed: Double {
        didSet {
            UserDefaults.standard.set(greenSpeed, forKey: Self.greenSpeedKey)
        }
    }
    @Published var computeMode: Gate55ComputeMode = .recommend
    @Published var manualV0: Double = 2.0
    @Published var manualBeta: Double = 0
    @Published var isComputing = false
    @Published var statusMessage = "추천 계산 대기"
    @Published var recommendation: Gate55Recommendation?
    @Published var forwardResult: Gate55ForwardResult?
    @Published var context: Gate55TerrainContext?
    @Published var thermalLevel: ThermalPerformance.Level = .nominal
    /// Speed Corridor 이산 인덱스 (안전→공격적).
    @Published var corridorIndex: Int = 0
    @Published private(set) var isApplyingCorridor = false

    /// AR 조준선에 쓸 현재 β (도).
    var aimBetaDegrees: Double {
        switch computeMode {
        case .recommend:
            return recommendation?.directionDegrees ?? 0
        case .forward:
            return manualBeta
        }
    }

    var hasAimLine: Bool {
        switch computeMode {
        case .recommend:
            return recommendation?.primary != nil
        case .forward:
            return forwardResult != nil
        }
    }

    var corridorCandidateCount: Int {
        recommendation?.corridorCandidates.count ?? 0
    }

    var corridorSliderEnabled: Bool {
        corridorCandidateCount >= 2
    }

    private var thermalObserver: NSObjectProtocol?
    private var recomputeGeneration = 0
    private var boundPhysicsScanID: String?
    private var boundPhysicsBall: ScanPose?
    private var boundPhysicsHole: ScanPose?

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.greenSpeedKey) as? Double
        greenSpeed = stored ?? 2.5
        thermalLevel = ThermalPerformance.level
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ThermalPerformance.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thermalLevel = ThermalPerformance.level
            }
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    func bind(scan: CompletedScan) {
        let physicsBall = scan.physicsStartPose
        let physicsHole = scan.physicsHolePose
        if boundPhysicsScanID == scan.id,
           boundPhysicsBall == physicsBall,
           boundPhysicsHole == physicsHole,
           context != nil {
            return
        }
        applyScanContext(scan: scan, physicsBall: physicsBall, physicsHole: physicsHole)
    }

    /// 홀 재앵커 등 — 물리 지형은 그대로, 표시용 상태만 갱신.
    func refreshDisplay(for scan: CompletedScan) {
        statusMessage = String(
            format: "홀까지 %.2fm",
            scan.holeDistance
        )
    }

    private func applyScanContext(
        scan: CompletedScan,
        physicsBall: ScanPose,
        physicsHole: ScanPose
    ) {
        do {
            context = try Gate55Validation.contextFromScan(
                result: scan.result,
                startPose: physicsBall,
                holePose: physicsHole
            )
            boundPhysicsScanID = scan.id
            boundPhysicsBall = physicsBall
            boundPhysicsHole = physicsHole
            thermalLevel = ThermalPerformance.level
            statusMessage = String(
                format: "홀까지 %.2fm · 추천 계산 중…",
                hypot(
                    physicsHole.worldX - physicsBall.worldX,
                    physicsHole.worldZ - physicsBall.worldZ
                )
            )
            recompute()
        } catch {
            boundPhysicsScanID = nil
            boundPhysicsBall = nil
            boundPhysicsHole = nil
            statusMessage = "지형 컨텍스트 실패: \(error.localizedDescription)"
        }
    }

    /// 그린스피드 프리셋/스테퍼 — 즉시 재계산.
    func setGreenSpeed(_ value: Double, recomputeImmediately: Bool = true) {
        let clamped = min(max(value, 1.5), 4.0)
        let rounded = (clamped * 10).rounded() / 10
        guard abs(greenSpeed - rounded) > 1e-9 else { return }
        greenSpeed = rounded
        if recomputeImmediately {
            recompute()
        }
    }

    func nudgeGreenSpeed(_ delta: Double) {
        setGreenSpeed(greenSpeed + delta)
    }

    func recompute() {
        guard let context else { return }
        isComputing = true
        recomputeGeneration += 1
        let generation = recomputeGeneration
        thermalLevel = ThermalPerformance.level
        let greenSpeed = self.greenSpeed
        let mode = computeMode
        let v0 = manualV0
        let beta = manualBeta
        let snapshot = context
        let points = PerformanceSettings.effectiveRecommendPointCount
        let taskPriority: TaskPriority =
            thermalLevel >= .serious ? .utility : .userInitiated
        Task.detached(priority: taskPriority) {
            switch mode {
            case .recommend:
                let result = Gate55Validation.recommend(
                    context: snapshot,
                    greenSpeed: greenSpeed,
                    velocityPointCount: points,
                    directionPointCount: points
                )
                await MainActor.run {
                    guard generation == self.recomputeGeneration else { return }
                    self.recommendation = result
                    self.forwardResult = nil
                    self.corridorIndex = result.defaultCorridorIndex
                    self.isComputing = false
                    let gridNote = "\(points)×\(points)"
                    switch result.searchTier {
                    case .verified:
                        self.statusMessage =
                            "후보 \(result.candidateCount)개 · 코리도 \(result.corridorCandidates.count)단계 (\(gridNote))"
                    case .relaxedCapture:
                        self.statusMessage =
                            "반경 완화 · 후보 \(result.candidateCount)개 (\(gridNote))"
                    case .expandedSearch:
                        self.statusMessage =
                            "확장 탐색 · 후보 \(result.candidateCount)개 (\(gridNote))"
                    case .proximityEstimate:
                        self.statusMessage =
                            "추정 경로 · 홀인 미검증 (\(gridNote))"
                    case .flatHeuristic:
                        self.statusMessage =
                            "거리 추정 · 브레이크 미반영 (\(gridNote))"
                    case .noPath:
                        self.statusMessage =
                            "홀인 경로 없음 · 스캔을 다시 하세요"
                    }
                }
            case .forward:
                let result = Gate55Validation.runForward(
                    context: snapshot,
                    greenSpeed: greenSpeed,
                    initialVelocity: v0,
                    directionDegrees: beta
                )
                await MainActor.run {
                    guard generation == self.recomputeGeneration else { return }
                    self.forwardResult = result
                    self.recommendation = nil
                    self.isComputing = false
                    self.statusMessage = String(
                        format: "순검증 정지 (%.2f, %.2f)",
                        result.stopPosition.x,
                        result.stopPosition.y
                    )
                }
            }
        }
    }

    /// Speed Corridor 눈금 변경 — 해당 후보로 v0/β/궤적만 갱신(격자 재탐색 없음).
    func selectCorridorIndex(_ index: Int) {
        guard let context, var rec = recommendation else { return }
        let count = rec.corridorCandidates.count
        guard count >= 1 else { return }
        let clamped = min(max(index, 0), count - 1)
        guard clamped != corridorIndex || abs(rec.initialVelocity - rec.corridorCandidates[clamped].candidate.initialVelocity) > 1e-9 else {
            corridorIndex = clamped
            return
        }
        corridorIndex = clamped
        let ranked = rec.corridorCandidates[clamped]
        isApplyingCorridor = true
        recomputeGeneration += 1
        let generation = recomputeGeneration
        let greenSpeed = self.greenSpeed
        let snapshot = context
        Task.detached(priority: .userInitiated) {
            let flat = Gate55Validation.flatDisplayEquivalentDistance(
                initialVelocity: ranked.candidate.initialVelocity
            )
            let forward = Gate55Validation.runForward(
                context: snapshot,
                greenSpeed: greenSpeed,
                initialVelocity: ranked.candidate.initialVelocity,
                directionDegrees: ranked.candidate.directionDegrees,
                recordTrajectory: true
            )
            await MainActor.run {
                guard generation == self.recomputeGeneration else {
                    self.isApplyingCorridor = false
                    return
                }
                rec.initialVelocity = ranked.candidate.initialVelocity
                rec.directionDegrees = ranked.candidate.directionDegrees
                rec.stopPosition = ranked.overrunStopPosition
                rec.overrunDistance = ranked.actualOverrunDistance
                rec.flatEquivalentDistance = flat
                rec.distanceAdjustment = flat - rec.horizontalDistance
                rec.trajectory = forward.trajectory
                rec.primary = ranked
                self.recommendation = rec
                self.isApplyingCorridor = false
            }
        }
    }
}
