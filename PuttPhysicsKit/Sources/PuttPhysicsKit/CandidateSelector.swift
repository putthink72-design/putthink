import Foundation

public struct RankedPuttCandidate: Sendable, Equatable {
    public var candidate: InitialConditionCandidate
    public var overrunStopPosition: PuttVector2
    /// 고정 오버런 목표점(X, 기본 0.35m)까지의 거리 — 1순위 선정용.
    public var distanceToOverrunTarget: Double
    /// 홀을 지난 뒤 실제 정지까지 굴러간 거리(퍼트 방향 투영, m). Speed Corridor 정렬용.
    public var actualOverrunDistance: Double
    public var usedRelaxedCaptureRadius: Bool
    public var searchTier: CandidateSearchTier

    public init(
        candidate: InitialConditionCandidate,
        overrunStopPosition: PuttVector2,
        distanceToOverrunTarget: Double,
        actualOverrunDistance: Double,
        usedRelaxedCaptureRadius: Bool,
        searchTier: CandidateSearchTier = .verified
    ) {
        self.candidate = candidate
        self.overrunStopPosition = overrunStopPosition
        self.distanceToOverrunTarget = distanceToOverrunTarget
        self.actualOverrunDistance = actualOverrunDistance
        self.usedRelaxedCaptureRadius = usedRelaxedCaptureRadius
        self.searchTier = searchTier
    }
}

public struct CandidateSelectionResult: Sendable, Equatable {
    public var allCandidates: [RankedPuttCandidate]
    public var primary: RankedPuttCandidate?
    public var secondary: RankedPuttCandidate?
    public var overrunTarget: PuttVector2
    public var usedRelaxedCaptureRadius: Bool
    public var searchTier: CandidateSearchTier

    public init(
        allCandidates: [RankedPuttCandidate],
        primary: RankedPuttCandidate?,
        secondary: RankedPuttCandidate?,
        overrunTarget: PuttVector2,
        usedRelaxedCaptureRadius: Bool,
        searchTier: CandidateSearchTier = .verified
    ) {
        self.allCandidates = allCandidates
        self.primary = primary
        self.secondary = secondary
        self.overrunTarget = overrunTarget
        self.usedRelaxedCaptureRadius = usedRelaxedCaptureRadius
        self.searchTier = searchTier
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
    public static let fallbackGridPointCount = 45

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

        let expanded = expandedSearchBounds(
            holeDistance: holeDistance,
            minimumVelocity: minimumVelocity,
            maximumVelocity: maximumVelocity,
            minimumDirectionDegrees: minimumDirectionDegrees,
            maximumDirectionDegrees: maximumDirectionDegrees
        )
        let fallbackPoints = min(fallbackGridPointCount, min(velocityPointCount, directionPointCount))

        // ① 정상 홀인
        if let result = scanHoleInCandidates(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: holePosition,
            direction: direction,
            overrunTarget: overrunTarget,
            minimumVelocity: minimumVelocity,
            maximumVelocity: maximumVelocity,
            velocityPointCount: velocityPointCount,
            minimumDirectionDegrees: minimumDirectionDegrees,
            maximumDirectionDegrees: maximumDirectionDegrees,
            directionPointCount: directionPointCount,
            captureRadius: 0.054,
            searchTier: .verified
        ) {
            return result
        }

        // ② 반경 완화
        if let result = scanHoleInCandidates(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: holePosition,
            direction: direction,
            overrunTarget: overrunTarget,
            minimumVelocity: minimumVelocity,
            maximumVelocity: maximumVelocity,
            velocityPointCount: velocityPointCount,
            minimumDirectionDegrees: minimumDirectionDegrees,
            maximumDirectionDegrees: maximumDirectionDegrees,
            directionPointCount: directionPointCount,
            captureRadius: relaxedCaptureRadius,
            searchTier: .relaxedCapture
        ) {
            return result
        }

        // ③ 확장 탐색 + 완화 캡처
        if let result = scanHoleInCandidates(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: holePosition,
            direction: direction,
            overrunTarget: overrunTarget,
            minimumVelocity: expanded.minimumVelocity,
            maximumVelocity: expanded.maximumVelocity,
            velocityPointCount: fallbackPoints,
            minimumDirectionDegrees: expanded.minimumDirectionDegrees,
            maximumDirectionDegrees: expanded.maximumDirectionDegrees,
            directionPointCount: fallbackPoints,
            captureRadius: relaxedCaptureRadius,
            searchTier: .expandedSearch
        ) {
            return result
        }

        return CandidateSelectionResult(
            allCandidates: [],
            primary: nil,
            secondary: nil,
            overrunTarget: overrunTarget,
            usedRelaxedCaptureRadius: false,
            searchTier: .noPath
        )
    }

    private static func scanHoleInCandidates<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        holePosition: PuttVector2,
        direction: PuttVector2,
        overrunTarget: PuttVector2,
        minimumVelocity: Double,
        maximumVelocity: Double,
        velocityPointCount: Int,
        minimumDirectionDegrees: Double,
        maximumDirectionDegrees: Double,
        directionPointCount: Int,
        captureRadius: Double,
        searchTier: CandidateSearchTier
    ) -> CandidateSelectionResult? {
        let raw = MultibreakPuttPhysics.scanExactGridParallel(
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
        guard !raw.isEmpty else { return nil }
        return rankCandidates(
            raw: raw,
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: holePosition,
            direction: direction,
            overrunTarget: overrunTarget,
            captureRadius: captureRadius,
            usedRelaxed: captureRadius > 0.054 + 1e-9,
            searchTier: searchTier
        )
    }

    private static func rankCandidates<Terrain: TerrainField>(
        raw: [InitialConditionCandidate],
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        holePosition: PuttVector2,
        direction: PuttVector2,
        overrunTarget: PuttVector2,
        captureRadius: Double,
        usedRelaxed: Bool,
        searchTier: CandidateSearchTier
    ) -> CandidateSelectionResult {
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
                    usedRelaxedCaptureRadius: usedRelaxed,
                    searchTier: searchTier
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
            usedRelaxedCaptureRadius: usedRelaxed,
            searchTier: searchTier
        )
    }

    private static func expandedSearchBounds(
        holeDistance: Double,
        minimumVelocity: Double,
        maximumVelocity: Double,
        minimumDirectionDegrees: Double,
        maximumDirectionDegrees: Double
    ) -> (
        minimumVelocity: Double,
        maximumVelocity: Double,
        minimumDirectionDegrees: Double,
        maximumDirectionDegrees: Double
    ) {
        let directionLimit = holeDistance >= 7 ? 45.0 : 35.0
        return (
            minimumVelocity: min(minimumVelocity, max(0.8, 1.0 - holeDistance * 0.015)),
            maximumVelocity: max(maximumVelocity, min(6.0, 1.2 + holeDistance * 0.35)),
            minimumDirectionDegrees: min(minimumDirectionDegrees, -directionLimit),
            maximumDirectionDegrees: max(maximumDirectionDegrees, directionLimit)
        )
    }

}
