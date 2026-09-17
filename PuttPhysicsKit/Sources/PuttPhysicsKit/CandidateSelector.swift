import Foundation

public struct RankedPuttCandidate: Sendable, Equatable {
    public var candidate: InitialConditionCandidate
    public var overrunStopPosition: PuttVector2
    /// 고정 오버런 목표점(X, 기본 0.35m)까지의 거리 — 1순위 선정용.
    public var distanceToOverrunTarget: Double
    /// 홀을 지난 뒤 실제 정지까지 굴러간 거리(퍼트 방향 투영, m). Speed Corridor 정렬용.
    /// ignoreCapture 기준. 서비스 코리도는 0.34–0.44m만 남긴다. 0은 컵에서 죽는 공이라 안전이 아니다.
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

public enum CandidateSearchStrategy: String, Sendable, Equatable {
    /// 기존 N×N 전수 격자.
    case grid
    /// 미스 부호로 v·β를 이분한 뒤 국소 격자. Dev 필드 실험용.
    case shooting
}

public enum CandidateSelector {
    public static let defaultOverrunDistance = 0.35
    /// 컵 홀인 검증 반경(5.4cm). 이보다 큰 캡처는 홀인이 아니다.
    public static let holeInCaptureRadius = 0.054
    public static let relaxedCaptureRadius = 0.5
    public static let fallbackGridPointCount = 45
    /// ignoreCapture 정지점이 홀 평면보다 이보다 짧으면 후보 제외(완화 캡처가 홀 앞에서 잡은 경우).
    public static let minAlongHoleMeters = -0.02
    /// 지시한 대로 쳤을 때 최소 성적: 홀 뒤 34–44cm에서 정지.
    public static let serviceOverrunMinMeters = 0.34
    public static let serviceOverrunMaxMeters = 0.44
    /// 스피드 코리도 기본 눈금(표시·1순위 목표).
    public static let preferredOverrunMeters = 0.35

    public static func isServiceOverrun(_ meters: Double) -> Bool {
        meters + 1e-9 >= serviceOverrunMinMeters && meters - 1e-9 <= serviceOverrunMaxMeters
    }

    /// 홀인(5.4cm)이거나, 홀 뒤 34–44cm에 이미 서 있으면 최소 성적 충족.
    public static func meetsServiceLine(
        searchTier: CandidateSearchTier,
        overrunDistance: Double
    ) -> Bool {
        searchTier == .verified || isServiceOverrun(overrunDistance)
    }

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
        directionPointCount: Int = 130,
        strategy: CandidateSearchStrategy = .grid
    ) -> CandidateSelectionResult {
        let frame = searchFrame(
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            overrunDistance: overrunDistance
        )
        if strategy == .shooting {
            return selectByShooting(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                frame: frame,
                minimumVelocity: minimumVelocity,
                maximumVelocity: maximumVelocity,
                minimumDirectionDegrees: minimumDirectionDegrees,
                maximumDirectionDegrees: maximumDirectionDegrees
            )
        }

        let expanded = expandedSearchBounds(
            holeDistance: holeDistance,
            minimumVelocity: minimumVelocity,
            maximumVelocity: maximumVelocity,
            minimumDirectionDegrees: minimumDirectionDegrees,
            maximumDirectionDegrees: maximumDirectionDegrees
        )
        let longPutt = holeDistance >= 6
        let firstMinV = longPutt ? expanded.minimumVelocity : minimumVelocity
        let firstMaxV = longPutt ? expanded.maximumVelocity : maximumVelocity
        let firstMinB = longPutt ? expanded.minimumDirectionDegrees : minimumDirectionDegrees
        let firstMaxB = longPutt ? expanded.maximumDirectionDegrees : maximumDirectionDegrees
        let fallbackPoints = min(fallbackGridPointCount, min(velocityPointCount, directionPointCount))

        // ① 정상 홀인 — 6m+는 처음부터 12m용 v·β 창.
        if let result = scanHoleInCandidates(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunTarget: frame.overrunTarget,
            minimumVelocity: firstMinV,
            maximumVelocity: firstMaxV,
            velocityPointCount: velocityPointCount,
            minimumDirectionDegrees: firstMinB,
            maximumDirectionDegrees: firstMaxB,
            directionPointCount: directionPointCount,
            captureRadius: holeInCaptureRadius,
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
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunTarget: frame.overrunTarget,
            minimumVelocity: firstMinV,
            maximumVelocity: firstMaxV,
            velocityPointCount: velocityPointCount,
            minimumDirectionDegrees: firstMinB,
            maximumDirectionDegrees: firstMaxB,
            directionPointCount: directionPointCount,
            captureRadius: relaxedCaptureRadius,
            searchTier: .relaxedCapture
        ) {
            return result
        }

        // ③ 짧은 퍼트만 확장 창을 한 번 더.
        if !longPutt, let result = scanHoleInCandidates(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunTarget: frame.overrunTarget,
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

        return drawableFallback(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            expanded: expanded
        )
    }

    private struct SearchFrame: Sendable {
        var holePosition: PuttVector2
        var direction: PuttVector2
        var overrunTarget: PuttVector2
        var overrunDistance: Double
    }

    private static func searchFrame(
        holeDistance: Double,
        holeDirectionDegrees: Double,
        overrunDistance: Double
    ) -> SearchFrame {
        let holeBeta = holeDirectionDegrees * .pi / 180.0
        let holePosition = PuttVector2(
            x: holeDistance * sin(holeBeta),
            y: holeDistance * cos(holeBeta)
        )
        let direction = PuttVector2(x: sin(holeBeta), y: cos(holeBeta))
        return SearchFrame(
            holePosition: holePosition,
            direction: direction,
            overrunTarget: PuttVector2(
                x: holePosition.x + overrunDistance * direction.x,
                y: holePosition.y + overrunDistance * direction.y
            ),
            overrunDistance: overrunDistance
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
            usedRelaxed: captureRadius > holeInCaptureRadius + 1e-9,
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
    ) -> CandidateSelectionResult? {
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
            let pastHoleX = overrun.finalPosition.x - holePosition.x
            let pastHoleY = overrun.finalPosition.y - holePosition.y
            let alongHole = pastHoleX * direction.x + pastHoleY * direction.y
            // 홀 앞에서 멈춘 경로(완화 캡처 등)는 오버런 0으로 위장되면 안 됨 → 코리도·1순위에서 제외.
            guard alongHole >= minAlongHoleMeters else { return }

            let distance = hypot(
                overrun.finalPosition.x - overrunTarget.x,
                overrun.finalPosition.y - overrunTarget.y
            )
            let actualOverrun = max(0, alongHole)
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
        var ranked = rankedSlots.ordered()
        guard !ranked.isEmpty else { return nil }

        var inBand = ranked.filter { isServiceOverrun($0.actualOverrunDistance) }
        if inBand.isEmpty,
           let seed = ranked.min(by: { $0.distanceToOverrunTarget < $1.distanceToOverrunTarget }),
           let adjusted = adjustedServiceCandidate(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: holePosition,
            direction: direction,
            overrunTarget: overrunTarget,
            seed: seed,
            usedRelaxed: usedRelaxed,
            searchTier: searchTier
           ) {
            ranked.append(adjusted)
            if isServiceOverrun(adjusted.actualOverrunDistance) {
                inBand = [adjusted]
            }
        }
        let primaryPool = inBand.isEmpty ? ranked : inBand
        let primary = primaryPool.min(by: { $0.distanceToOverrunTarget < $1.distanceToOverrunTarget })
        let secondary = ranked.min(
            by: { $0.candidate.result.ballSpeedForHole < $1.candidate.result.ballSpeedForHole }
        )

        return CandidateSelectionResult(
            allCandidates: ranked,
            primary: primary,
            secondary: secondary,
            overrunTarget: overrunTarget,
            usedRelaxedCaptureRadius: usedRelaxed,
            searchTier: primary?.searchTier ?? searchTier
        )
    }

    /// 격자 눈금이 34–44cm를 건너뛰면 같은 β에서 속도를 0.35m까지 이분한다.
    private static func adjustedServiceCandidate<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        holePosition: PuttVector2,
        direction: PuttVector2,
        overrunTarget: PuttVector2,
        seed: RankedPuttCandidate,
        usedRelaxed: Bool,
        searchTier: CandidateSearchTier
    ) -> RankedPuttCandidate? {
        let overrunDistance = hypot(
            overrunTarget.x - holePosition.x,
            overrunTarget.y - holePosition.y
        )
        let expanded = expandedSearchBounds(
            holeDistance: holeDistance,
            minimumVelocity: 0.8,
            maximumVelocity: 6.0,
            minimumDirectionDegrees: -45,
            maximumDirectionDegrees: 45
        )
        let velocity = binarySearchVelocity(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: holePosition,
            direction: direction,
            overrunDistance: overrunDistance,
            betaDegrees: seed.candidate.directionDegrees,
            minimumVelocity: expanded.minimumVelocity,
            maximumVelocity: expanded.maximumVelocity
        )
        let frame = SearchFrame(
            holePosition: holePosition,
            direction: direction,
            overrunTarget: overrunTarget,
            overrunDistance: overrunDistance
        )
        guard var ranked = rankedLaunch(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            velocity: velocity,
            betaDegrees: seed.candidate.directionDegrees,
            tier: searchTier,
            requireReachHole: true
        ) else { return nil }
        ranked.usedRelaxedCaptureRadius = usedRelaxed
        if searchTier == .verified && ranked.candidate.result.ballHoleIf != 1 {
            ranked.searchTier = .proximityEstimate
        }
        return ranked
    }

    /// 홀 평면 미스 부호로 조준각·속도를 이분한 뒤, 그 주변만 5.4cm 캡처 격자로 검증한다.
    private static func selectByShooting<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        frame: SearchFrame,
        minimumVelocity: Double,
        maximumVelocity: Double,
        minimumDirectionDegrees: Double,
        maximumDirectionDegrees: Double
    ) -> CandidateSelectionResult {
        let expanded = expandedSearchBounds(
            holeDistance: holeDistance,
            minimumVelocity: minimumVelocity,
            maximumVelocity: maximumVelocity,
            minimumDirectionDegrees: minimumDirectionDegrees,
            maximumDirectionDegrees: maximumDirectionDegrees
        )
        let seed = shootingSeed(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            expanded: expanded
        )
        let vSpan = max(0.18, (expanded.maximumVelocity - expanded.minimumVelocity) * 0.08)
        let betaSpan = max(4.0, (expanded.maximumDirectionDegrees - expanded.minimumDirectionDegrees) * 0.12)
        let local = scanHoleInCandidates(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunTarget: frame.overrunTarget,
            minimumVelocity: max(expanded.minimumVelocity, seed.velocity - vSpan),
            maximumVelocity: min(expanded.maximumVelocity, seed.velocity + vSpan),
            velocityPointCount: 9,
            minimumDirectionDegrees: max(expanded.minimumDirectionDegrees, seed.betaDegrees - betaSpan),
            maximumDirectionDegrees: min(expanded.maximumDirectionDegrees, seed.betaDegrees + betaSpan),
            directionPointCount: 9,
            captureRadius: holeInCaptureRadius,
            searchTier: .verified
        )
        if let local {
            return local
        }
        return drawableFallback(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            expanded: expanded,
            seed: seed
        )
    }

    private struct ShootingSeed: Sendable {
        var velocity: Double
        var betaDegrees: Double
    }

    private static func shootingSeed<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        frame: SearchFrame,
        expanded: (
            minimumVelocity: Double,
            maximumVelocity: Double,
            minimumDirectionDegrees: Double,
            maximumDirectionDegrees: Double
        )
    ) -> ShootingSeed {
        let vSeed = binarySearchVelocity(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunDistance: frame.overrunDistance,
            betaDegrees: 0,
            minimumVelocity: expanded.minimumVelocity,
            maximumVelocity: expanded.maximumVelocity
        )
        let betaSeed = binarySearchDirection(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            velocity: vSeed,
            minimumDirectionDegrees: expanded.minimumDirectionDegrees,
            maximumDirectionDegrees: expanded.maximumDirectionDegrees
        )
        let vRefined = binarySearchVelocity(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunDistance: frame.overrunDistance,
            betaDegrees: betaSeed,
            minimumVelocity: expanded.minimumVelocity,
            maximumVelocity: expanded.maximumVelocity
        )
        return ShootingSeed(velocity: vRefined, betaDegrees: betaSeed)
    }

    /// 5.4cm 격자가 비어도 홀 뒤 0.35m까지 올린 추정 궤적을 그린다. 재스캔 화면을 만들지 않는다.
    private static func drawableFallback<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        frame: SearchFrame,
        expanded: (
            minimumVelocity: Double,
            maximumVelocity: Double,
            minimumDirectionDegrees: Double,
            maximumDirectionDegrees: Double
        ),
        seed: ShootingSeed? = nil
    ) -> CandidateSelectionResult {
        let resolved = seed ?? shootingSeed(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            expanded: expanded
        )
        let raised = binarySearchVelocity(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunDistance: frame.overrunDistance,
            betaDegrees: resolved.betaDegrees,
            minimumVelocity: expanded.minimumVelocity,
            maximumVelocity: expanded.maximumVelocity
        )
        let attempts: [(Double, Double, CandidateSearchTier)] = [
            (raised, resolved.betaDegrees, .proximityEstimate),
            (expanded.maximumVelocity, resolved.betaDegrees, .proximityEstimate),
            (expanded.maximumVelocity, 0, .flatHeuristic)
        ]
        var bestPastHole: RankedPuttCandidate?
        var bestPastHoleTier: CandidateSearchTier = .proximityEstimate
        for (velocity, beta, tier) in attempts {
            guard let ranked = rankedLaunch(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                frame: frame,
                velocity: velocity,
                betaDegrees: beta,
                tier: tier,
                requireReachHole: true
            ) else { continue }
            if ranked.actualOverrunDistance + 1e-9 >= serviceOverrunMinMeters {
                return CandidateSelectionResult(
                    allCandidates: [ranked],
                    primary: ranked,
                    secondary: ranked,
                    overrunTarget: frame.overrunTarget,
                    usedRelaxedCaptureRadius: false,
                    searchTier: tier
                )
            }
            if bestPastHole == nil
                || ranked.actualOverrunDistance > (bestPastHole?.actualOverrunDistance ?? -1) {
                bestPastHole = ranked
                bestPastHoleTier = tier
            }
        }
        if let bestPastHole {
            return CandidateSelectionResult(
                allCandidates: [bestPastHole],
                primary: bestPastHole,
                secondary: bestPastHole,
                overrunTarget: frame.overrunTarget,
                usedRelaxedCaptureRadius: false,
                searchTier: bestPastHoleTier
            )
        }
        let last = rankedLaunch(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            velocity: max(expanded.maximumVelocity, 2.5),
            betaDegrees: 0,
            tier: .flatHeuristic,
            requireReachHole: false
        )
        if let last {
            return CandidateSelectionResult(
                allCandidates: [last],
                primary: last,
                secondary: last,
                overrunTarget: frame.overrunTarget,
                usedRelaxedCaptureRadius: false,
                searchTier: .flatHeuristic
            )
        }
        return syntheticStraightSelection(frame: frame, holeDistance: holeDistance)
    }

    /// 물리 적분까지 실패해도 볼→홀+0.35m 직선 후보는 남긴다. 빈 화면 금지.
    private static func syntheticStraightSelection(
        frame: SearchFrame,
        holeDistance: Double
    ) -> CandidateSelectionResult {
        let velocity = max(1.2, min(6.0, 1.15 + holeDistance * 0.28))
        let stop = frame.overrunTarget
        let result = FlatPuttResult(
            ballStopIf: 1,
            finalPosition: stop,
            ballSpeedForHole: velocity
        )
        let ranked = RankedPuttCandidate(
            candidate: InitialConditionCandidate(
                initialVelocity: velocity,
                directionDegrees: 0,
                result: result
            ),
            overrunStopPosition: stop,
            distanceToOverrunTarget: 0,
            actualOverrunDistance: frame.overrunDistance,
            usedRelaxedCaptureRadius: false,
            searchTier: .flatHeuristic
        )
        return CandidateSelectionResult(
            allCandidates: [ranked],
            primary: ranked,
            secondary: ranked,
            overrunTarget: frame.overrunTarget,
            usedRelaxedCaptureRadius: false,
            searchTier: .flatHeuristic
        )
    }

    private static func rankedLaunch<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        frame: SearchFrame,
        velocity: Double,
        betaDegrees: Double,
        tier: CandidateSearchTier,
        requireReachHole: Bool
    ) -> RankedPuttCandidate? {
        let captured = MultibreakPuttPhysics.simulate(
            configuration: MultibreakPuttConfiguration(
                greenSpeed: greenSpeed,
                initialVelocity: velocity,
                initialDirectionDegrees: betaDegrees,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees
            ),
            terrain: terrain,
            recordTrajectory: false,
            captureRadius: holeInCaptureRadius
        )
        let overrun = MultibreakPuttPhysics.simulate(
            configuration: MultibreakPuttConfiguration(
                greenSpeed: greenSpeed,
                initialVelocity: velocity,
                initialDirectionDegrees: betaDegrees,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees
            ),
            terrain: terrain,
            recordTrajectory: false,
            ignoreCapture: true
        )
        let pastHoleX = overrun.finalPosition.x - frame.holePosition.x
        let pastHoleY = overrun.finalPosition.y - frame.holePosition.y
        let alongHole = pastHoleX * frame.direction.x + pastHoleY * frame.direction.y
        if requireReachHole, alongHole < minAlongHoleMeters {
            return nil
        }
        let distance = hypot(
            overrun.finalPosition.x - frame.overrunTarget.x,
            overrun.finalPosition.y - frame.overrunTarget.y
        )
        return RankedPuttCandidate(
            candidate: InitialConditionCandidate(
                initialVelocity: velocity,
                directionDegrees: betaDegrees,
                result: captured
            ),
            overrunStopPosition: overrun.finalPosition,
            distanceToOverrunTarget: distance,
            actualOverrunDistance: max(0, alongHole),
            usedRelaxedCaptureRadius: false,
            searchTier: tier
        )
    }

    private static func binarySearchVelocity<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        holePosition: PuttVector2,
        direction: PuttVector2,
        overrunDistance: Double,
        betaDegrees: Double,
        minimumVelocity: Double,
        maximumVelocity: Double
    ) -> Double {
        var lo = minimumVelocity
        var hi = maximumVelocity
        for _ in 0..<12 {
            let mid = (lo + hi) * 0.5
            let along = coastAlongHole(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: holePosition,
                direction: direction,
                velocity: mid,
                betaDegrees: betaDegrees
            )
            if along < holeDistance + overrunDistance {
                lo = mid
            } else {
                hi = mid
            }
        }
        // 하한(lo)은 짧은 쪽. 홀 앞 죽음을 피하려면 도달 상한(hi)을 쓴다.
        return hi
    }

    private static func binarySearchDirection<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        holePosition: PuttVector2,
        direction: PuttVector2,
        velocity: Double,
        minimumDirectionDegrees: Double,
        maximumDirectionDegrees: Double
    ) -> Double {
        var lo = minimumDirectionDegrees
        var hi = maximumDirectionDegrees
        var best = 0.0
        for _ in 0..<14 {
            let mid = (lo + hi) * 0.5
            let lateral = coastLateralMiss(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: holePosition,
                direction: direction,
                velocity: velocity,
                betaDegrees: mid
            )
            best = mid
            // +β = +local X. 홀 오른쪽(+) 미스면 조준을 왼쪽으로.
            if lateral > 0 {
                hi = mid
            } else {
                lo = mid
            }
        }
        return best
    }

    private static func coastAlongHole<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        holePosition: PuttVector2,
        direction: PuttVector2,
        velocity: Double,
        betaDegrees: Double
    ) -> Double {
        let coast = MultibreakPuttPhysics.simulate(
            configuration: MultibreakPuttConfiguration(
                greenSpeed: greenSpeed,
                initialVelocity: velocity,
                initialDirectionDegrees: betaDegrees,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees
            ),
            terrain: terrain,
            recordTrajectory: false,
            ignoreCapture: true
        )
        let dx = coast.finalPosition.x - holePosition.x
        let dy = coast.finalPosition.y - holePosition.y
        return dx * direction.x + dy * direction.y + holeDistance
    }

    private static func coastLateralMiss<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        holePosition: PuttVector2,
        direction: PuttVector2,
        velocity: Double,
        betaDegrees: Double
    ) -> Double {
        let coast = MultibreakPuttPhysics.simulate(
            configuration: MultibreakPuttConfiguration(
                greenSpeed: greenSpeed,
                initialVelocity: velocity,
                initialDirectionDegrees: betaDegrees,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees
            ),
            terrain: terrain,
            recordTrajectory: false,
            ignoreCapture: true
        )
        let right = PuttVector2(x: direction.y, y: -direction.x)
        let dx = coast.finalPosition.x - holePosition.x
        let dy = coast.finalPosition.y - holePosition.y
        return dx * right.x + dy * right.y
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
