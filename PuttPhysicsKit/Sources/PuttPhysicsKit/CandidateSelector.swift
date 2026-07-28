import Foundation

public struct RankedPuttCandidate: Sendable, Equatable {
    public var candidate: InitialConditionCandidate
    public var overrunStopPosition: PuttVector2
    /// 고정 오버런 목표점(X, 기본 0.35m)까지의 거리 — 1순위 선정용.
    public var distanceToOverrunTarget: Double
    /// 홀을 지난 뒤 실제 정지까지 굴러간 거리(퍼트 방향 투영, m). Speed Corridor 정렬용.
    public var actualOverrunDistance: Double
    public var usedRelaxedCaptureRadius: Bool

    public init(
        candidate: InitialConditionCandidate,
        overrunStopPosition: PuttVector2,
        distanceToOverrunTarget: Double,
        actualOverrunDistance: Double,
        usedRelaxedCaptureRadius: Bool
    ) {
        self.candidate = candidate
        self.overrunStopPosition = overrunStopPosition
        self.distanceToOverrunTarget = distanceToOverrunTarget
        self.actualOverrunDistance = actualOverrunDistance
        self.usedRelaxedCaptureRadius = usedRelaxedCaptureRadius
    }
}

public struct CandidateSelectionResult: Sendable, Equatable {
    public var allCandidates: [RankedPuttCandidate]
    public var primary: RankedPuttCandidate?
    public var secondary: RankedPuttCandidate?
    public var overrunTarget: PuttVector2
    public var usedRelaxedCaptureRadius: Bool

    public init(
        allCandidates: [RankedPuttCandidate],
        primary: RankedPuttCandidate?,
        secondary: RankedPuttCandidate?,
        overrunTarget: PuttVector2,
        usedRelaxedCaptureRadius: Bool
    ) {
        self.allCandidates = allCandidates
        self.primary = primary
        self.secondary = secondary
        self.overrunTarget = overrunTarget
        self.usedRelaxedCaptureRadius = usedRelaxedCaptureRadius
    }
}

private final class LockedRankedCandidates: @unchecked Sendable {
    private var slots: [RankedPuttCandidate?]
    private let lock = NSLock()

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    func set(_ candidate: RankedPuttCandidate, at index: Int) {
        lock.lock()
        slots[index] = candidate
        lock.unlock()
    }

    func ordered() -> [RankedPuttCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return slots.compactMap { $0 }
    }
}

public enum CandidateSelector {
    public static let defaultOverrunDistance = 0.35
    public static let relaxedCaptureRadius = 0.5

    public static func select<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double = 0,
        overrunDistance: Double = defaultOverrunDistance,
        minimumVelocity: Double = 1.0,
        maximumVelocity: Double = 4.0,
        velocityPointCount: Int = 130,
        minimumDirectionDegrees: Double = -30,
        maximumDirectionDegrees: Double = 30,
        directionPointCount: Int = 130
    ) -> CandidateSelectionResult {
        let holeBeta = holeDirectionDegrees * .pi / 180.0
        let holePosition = PuttVector2(
            x: holeDistance * sin(holeBeta),
            y: holeDistance * cos(holeBeta)
        )
        let direction = PuttVector2(x: sin(holeBeta), y: cos(holeBeta))
        let overrunTarget = PuttVector2(
            x: holePosition.x + overrunDistance * direction.x,
            y: holePosition.y + overrunDistance * direction.y
        )

        var captureRadius = 0.054
        var usedRelaxed = false
        var raw = MultibreakPuttPhysics.scanExactGridParallel(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            minimumVelocity: minimumVelocity,
            maximumVelocity: maximumVelocity,
            velocityPointCount: velocityPointCount,
            minimumDirectionDegrees: minimumDirectionDegrees,
            maximumDirectionDegrees: maximumDirectionDegrees,
            directionPointCount: directionPointCount,
            captureRadius: captureRadius
        )

        if raw.isEmpty {
            captureRadius = relaxedCaptureRadius
            usedRelaxed = true
            raw = MultibreakPuttPhysics.scanExactGridParallel(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                minimumVelocity: minimumVelocity,
                maximumVelocity: maximumVelocity,
                velocityPointCount: velocityPointCount,
                minimumDirectionDegrees: minimumDirectionDegrees,
                maximumDirectionDegrees: maximumDirectionDegrees,
                directionPointCount: directionPointCount,
                captureRadius: captureRadius
            )
        }

        // 후보별 오버런 시뮬레이션은 서로 독립이므로 병렬 실행(입력 순서 유지).
        let rankedSlots = LockedRankedCandidates(count: raw.count)
        DispatchQueue.concurrentPerform(iterations: raw.count) { index in
            let candidate = raw[index]
            let overrun = MultibreakPuttPhysics.simulate(
                configuration: MultibreakPuttConfiguration(
                    greenSpeed: greenSpeed,
                    initialVelocity: candidate.initialVelocity,
                    initialDirectionDegrees: candidate.directionDegrees,
                    holeDistance: holeDistance,
                    holeDirectionDegrees: holeDirectionDegrees
                ),
                terrain: terrain,
                recordTrajectory: false,
                ignoreCapture: true,
                captureRadius: captureRadius
            )
            let distance = hypot(
                overrun.finalPosition.x - overrunTarget.x,
                overrun.finalPosition.y - overrunTarget.y
            )
            let pastHoleX = overrun.finalPosition.x - holePosition.x
            let pastHoleY = overrun.finalPosition.y - holePosition.y
            let actualOverrun = max(0, pastHoleX * direction.x + pastHoleY * direction.y)
            rankedSlots.set(
                RankedPuttCandidate(
                    candidate: candidate,
                    overrunStopPosition: overrun.finalPosition,
                    distanceToOverrunTarget: distance,
                    actualOverrunDistance: actualOverrun,
                    usedRelaxedCaptureRadius: usedRelaxed
                ),
                at: index
            )
        }
        let ranked = rankedSlots.ordered()

        let primary = ranked.min(by: { $0.distanceToOverrunTarget < $1.distanceToOverrunTarget })
        let secondary = ranked.min(
            by: { $0.candidate.result.ballSpeedForHole < $1.candidate.result.ballSpeedForHole }
        )

        return CandidateSelectionResult(
            allCandidates: ranked,
            primary: primary,
            secondary: secondary,
            overrunTarget: overrunTarget,
            usedRelaxedCaptureRadius: usedRelaxed
        )
    }
}
