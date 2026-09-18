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
    static let greenSpeedPresets: [Double] = [2.0, 2.5, 3.0, 3.5, 4.0]

    @Published var greenSpeed: Double {
        didSet {
            UserDefaults.standard.set(greenSpeed, forKey: Self.greenSpeedKey)
        }
    }
    @Published var computeMode: Gate55ComputeMode = .recommend
    @Published var manualV0: Double = 2.0
    @Published var manualBeta: Double = 0
    @Published var isComputing = false
    @Published var statusMessage = L10n.statusWaiting
    @Published var recommendation: Gate55Recommendation?
    @Published var forwardResult: Gate55ForwardResult?
    @Published var context: Gate55TerrainContext?
    @Published var thermalLevel: ThermalPerformance.Level = .nominal
    /// Speed Corridor 이산 인덱스 (짧음 34cm → 조금 지남 44cm).
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

    private nonisolated(unsafe) var thermalObserver: NSObjectProtocol?
    private var recomputeGeneration = 0
    private var boundPhysicsScanID: String?
    private var boundPhysicsBall: ScanPose?
    private var boundPhysicsHole: ScanPose?

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.greenSpeedKey) as? Double
        greenSpeed = GreenSpeedSettings.clamped(stored ?? GreenSpeedSettings.defaultMeters)
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
        statusMessage = L10n.holeDistance(scan.holeDistance)
    }

    /// 언어 변경 시 이미 만든 상태 문구를 현재 locale로 다시 쓴다.
    func refreshLocalizedCopy() {
        if let rec = recommendation, rec.primary != nil {
            statusMessage = L10n.status(
                tier: rec.searchTier,
                candidateCount: rec.candidateCount,
                corridorCount: rec.corridorCandidates.count,
                gridNote: ""
            )
        } else if isComputing, let context {
            statusMessage = L10n.computingForHole(context.holeDistance)
        } else if let context {
            statusMessage = L10n.holeDistance(context.holeDistance)
        } else {
            statusMessage = L10n.statusWaiting
        }
    }

    private func applyScanContext(
        scan: CompletedScan,
        physicsBall: ScanPose,
        physicsHole: ScanPose
    ) {
        let holeD = hypot(
            physicsHole.worldX - physicsBall.worldX,
            physicsHole.worldZ - physicsBall.worldZ
        )
        recommendation = nil
        forwardResult = nil
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
            statusMessage = L10n.computingForHole(holeD)
            recompute()
        } catch {
            boundPhysicsScanID = nil
            boundPhysicsBall = nil
            boundPhysicsHole = nil
            isComputing = false
            statusMessage = L10n.contextFailed(error.localizedDescription)
        }
    }

    /// 그린스피드 프리셋/스테퍼 — 즉시 재계산.
    func setGreenSpeed(_ value: Double, recomputeImmediately: Bool = true) {
        let rounded = GreenSpeedSettings.clamped(value)
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
        let coarsePoints = RecommendScanGrid.light.rawValue
        let finePoints = RecommendScanGrid.balanced.rawValue
        let started = Date()
        Task.detached(priority: .userInitiated) {
            switch mode {
            case .recommend:
                let shoot = Gate55Validation.recommend(
                    context: snapshot,
                    greenSpeed: greenSpeed,
                    velocityPointCount: coarsePoints,
                    directionPointCount: coarsePoints,
                    searchStrategy: .shooting
                )
                let keepRefining = !CandidateSelector.meetsServiceLine(
                    searchTier: shoot.searchTier,
                    overrunDistance: shoot.overrunDistance,
                    policy: shoot.overrunPolicy
                )
                await MainActor.run {
                    self.applyRecommend(
                        shoot,
                        generation: generation,
                        gridNote: "shoot",
                        stillComputing: keepRefining
                    )
                }
                guard keepRefining else { return }

                let coarse = Gate55Validation.recommend(
                    context: snapshot,
                    greenSpeed: greenSpeed,
                    velocityPointCount: coarsePoints,
                    directionPointCount: coarsePoints
                )
                let betterCoarse = Self.preferRecommend(incoming: coarse, current: shoot)
                let elapsed = Date().timeIntervalSince(started)
                // 90×90은 발열 대비 이득이 작다. 선이 있으면 생략.
                let skipFine = betterCoarse.primary != nil
                    || elapsed >= 2.5
                    || ThermalPerformance.level >= .fair
                await MainActor.run {
                    self.applyRecommend(
                        betterCoarse,
                        generation: generation,
                        gridNote: "\(coarsePoints)×\(coarsePoints)",
                        stillComputing: !skipFine
                    )
                }
                guard !skipFine else { return }

                let fine = Gate55Validation.recommend(
                    context: snapshot,
                    greenSpeed: greenSpeed,
                    velocityPointCount: finePoints,
                    directionPointCount: finePoints
                )
                let best = Self.preferRecommend(incoming: fine, current: betterCoarse)
                await MainActor.run {
                    self.applyRecommend(
                        best,
                        generation: generation,
                        gridNote: "\(finePoints)×\(finePoints)"
                    )
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

    private func applyRecommend(
        _ result: Gate55Recommendation,
        generation: Int,
        gridNote: String,
        stillComputing: Bool = false
    ) {
        guard generation == recomputeGeneration else { return }
        if result.primary == nil, recommendation?.primary != nil {
            isComputing = stillComputing
            return
        }
        recommendation = result
        forwardResult = nil
        corridorIndex = result.defaultCorridorIndex
        isComputing = stillComputing
        statusMessage = L10n.status(
            tier: result.searchTier,
            candidateCount: result.candidateCount,
            corridorCount: result.corridorCandidates.count,
            gridNote: gridNote
        )
    }

    nonisolated private static func preferRecommend(
        incoming: Gate55Recommendation,
        current: Gate55Recommendation
    ) -> Gate55Recommendation {
        if incoming.primary == nil { return current }
        if current.primary == nil { return incoming }
        if incoming.searchTier.displayPriority != current.searchTier.displayPriority {
            return incoming.searchTier.displayPriority > current.searchTier.displayPriority
                ? incoming : current
        }
        if incoming.candidateCount != current.candidateCount {
            return incoming.candidateCount > current.candidateCount ? incoming : current
        }
        return incoming
    }

    /// Speed Corridor 눈금 변경 — 해당 후보로 v0/β/궤적만 갱신(격자 재탐색 없음).
    func selectCorridorIndex(_ index: Int) {
        guard let context, var rec = recommendation else { return }
        let count = rec.corridorCandidates.count
        guard count >= 1 else { return }
        let clamped = min(max(index, 0), count - 1)
        let ranked = rec.corridorCandidates[clamped]
        guard clamped != corridorIndex || abs(rec.initialVelocity - ranked.candidate.initialVelocity) > 1e-9 else {
            corridorIndex = clamped
            return
        }
        corridorIndex = clamped
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
