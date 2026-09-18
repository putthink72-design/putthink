import Foundation

public struct RankedPuttCandidate: Sendable, Equatable {
    public var candidate: InitialConditionCandidate
    public var overrunStopPosition: PuttVector2
    /// 고정 오버런 목표점(X, 기본 0.35m)까지의 거리 — 1순위 선정용.
    public var distanceToOverrunTarget: Double
    /// 홀을 지난 뒤 실제 정지까지 굴러간 거리(퍼트 방향 투영, m). Speed Corridor 정렬용.
    /// ignoreCapture 기준. 서비스 코리도는 `ServiceOverrunPolicy` 밴드만 남긴다.
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
    public var overrunPolicy: ServiceOverrunPolicy

    public init(
        allCandidates: [RankedPuttCandidate],
        primary: RankedPuttCandidate?,
        secondary: RankedPuttCandidate?,
        overrunTarget: PuttVector2,
        usedRelaxedCaptureRadius: Bool,
        searchTier: CandidateSearchTier = .verified,
        overrunPolicy: ServiceOverrunPolicy = .flat
    ) {
        self.allCandidates = allCandidates
        self.primary = primary
        self.secondary = secondary
        self.overrunTarget = overrunTarget
        self.usedRelaxedCaptureRadius = usedRelaxedCaptureRadius
        self.searchTier = searchTier
        self.overrunPolicy = overrunPolicy
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
    /// 홀 평면 미스 부호로 v·β를 이분한 뒤 국소 격자.
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
    /// 지시한 대로 쳤을 때 최소 성적: 평지·오르막은 홀 뒤 34–44cm.
    public static let serviceOverrunMinMeters = 0.34
    public static let serviceOverrunMaxMeters = 0.44
    /// 스피드 코리도 기본 눈금(평지·오르막).
    public static let preferredOverrunMeters = 0.35
    /// 추정 궤적도 108mm 컵 안(반경 5.4cm)을 지나야 한다. 더 느슨하면 컵 옆 미스가 홀인처럼 보인다.
    public static let displayCupPassRadius = holeInCaptureRadius
    /// 탐색 적분은 홀 뒤 여기까지만. 서비스 밴드(≤44cm)보다 길고, 내리막 20초 폭주를 막는다.
    public static let searchCoastPastHoleMeters = 0.80

    private static func searchTimeFinal(holeDistance: Double) -> Double {
        min(12.0, 3.0 + holeDistance * 0.6)
    }

    private static func searchSimulate<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        velocity: Double,
        betaDegrees: Double,
        ignoreCapture: Bool,
        captureRadius: Double = holeInCaptureRadius,
        recordTrajectory: Bool = false
    ) -> FlatPuttResult {
        MultibreakPuttPhysics.simulate(
            configuration: MultibreakPuttConfiguration(
                greenSpeed: greenSpeed,
                initialVelocity: velocity,
                initialDirectionDegrees: betaDegrees,
                timeFinal: searchTimeFinal(holeDistance: holeDistance),
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees
            ),
            terrain: terrain,
            recordTrajectory: recordTrajectory,
            ignoreCapture: ignoreCapture,
            captureRadius: captureRadius,
            maxAlongHoleMeters: holeDistance + searchCoastPastHoleMeters
        )
    }

    public static func isServiceOverrun(
        _ meters: Double,
        policy: ServiceOverrunPolicy = .flat
    ) -> Bool {
        policy.contains(meters)
    }

    /// 홀인(5.4cm)이거나, 현재 경사 정책의 오버런 밴드에 서 있으면 최소 성적 충족.
    public static func meetsServiceLine(
        searchTier: CandidateSearchTier,
        overrunDistance: Double,
        policy: ServiceOverrunPolicy = .flat
    ) -> Bool {
        searchTier == .verified || policy.contains(overrunDistance)
    }

    public static func select<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double = 0,
        overrunDistance: Double? = nil,
        minimumVelocity: Double = 1.0,
        maximumVelocity: Double = 4.0,
        velocityPointCount: Int = 130,
        minimumDirectionDegrees: Double = -30,
        maximumDirectionDegrees: Double = 30,
        directionPointCount: Int = 130,
        strategy: CandidateSearchStrategy = .grid
    ) -> CandidateSelectionResult {
        let policy: ServiceOverrunPolicy
        let targetOverrun: Double
        if let overrunDistance {
            policy = ServiceOverrunPolicy.targeting(overrunDistance)
            targetOverrun = overrunDistance
        } else {
            policy = ServiceOverrunPolicy.make(
                terrain: terrain,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees
            )
            targetOverrun = policy.preferredMeters
        }
        let frame = searchFrame(
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            overrunDistance: targetOverrun,
            policy: policy
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
            searchTier: .verified,
            policy: frame.policy
        ) {
            return result
        }

        // ② 반경 완화 — 50cm 캡처여도 표시 선은 컵(5.4cm) 안을 지나야 한다.
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
            searchTier: .relaxedCapture,
            policy: frame.policy
        ), launchPassesCup(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            candidate: result.primary
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
            searchTier: .expandedSearch,
            policy: frame.policy
        ), launchPassesCup(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            candidate: result.primary
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
        var policy: ServiceOverrunPolicy
    }

    private static func searchFrame(
        holeDistance: Double,
        holeDirectionDegrees: Double,
        overrunDistance: Double,
        policy: ServiceOverrunPolicy
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
            overrunDistance: overrunDistance,
            policy: policy
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
            searchTier: CandidateSearchTier,
            policy: ServiceOverrunPolicy
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
            timeFinal: searchTimeFinal(holeDistance: holeDistance),
            captureRadius: captureRadius,
            maxAlongHoleMeters: holeDistance + searchCoastPastHoleMeters
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
            searchTier: searchTier,
            policy: policy
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
        searchTier: CandidateSearchTier,
        policy: ServiceOverrunPolicy
    ) -> CandidateSelectionResult? {
        let rankedSlots = LockedRankedCandidates(count: raw.count)
        DispatchQueue.concurrentPerform(iterations: raw.count) { index in
            let candidate = raw[index]
            let overrun = searchSimulate(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                velocity: candidate.initialVelocity,
                betaDegrees: candidate.directionDegrees,
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

        var inBand = ranked.filter { policy.contains($0.actualOverrunDistance) }
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
            searchTier: searchTier,
            policy: policy
           ) {
            ranked.append(adjusted)
            if policy.contains(adjusted.actualOverrunDistance) {
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
            searchTier: primary?.searchTier ?? searchTier,
            overrunPolicy: policy
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
        searchTier: CandidateSearchTier,
        policy: ServiceOverrunPolicy
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
            overrunDistance: overrunDistance,
            policy: policy
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

    /// 홀을 지나는 조준각을 잡은 뒤 속도를 경사 정책 오버런까지 이분하고, 그 주변만 5.4cm 캡처 격자로 검증한다.
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
        let seedGeometry = closestApproachToHole(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            velocity: seed.velocity,
            betaDegrees: seed.betaDegrees
        )
        var aimedSeed = seed
        if !(seedGeometry.reached && seedGeometry.closest <= displayCupPassRadius) {
            aimedSeed = aimThroughCup(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                frame: frame,
                expanded: expanded,
                seed: seed
            )
        }
        let aimedGeometry = closestApproachToHole(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            velocity: aimedSeed.velocity,
            betaDegrees: aimedSeed.betaDegrees
        )
        let seedHitsCup = aimedGeometry.reached && aimedGeometry.closest <= displayCupPassRadius
        let vSpan = max(0.18, (expanded.maximumVelocity - expanded.minimumVelocity) * 0.08)
        let betaSpan = seedHitsCup
            ? max(4.0, (expanded.maximumDirectionDegrees - expanded.minimumDirectionDegrees) * 0.12)
            : max(14.0, (expanded.maximumDirectionDegrees - expanded.minimumDirectionDegrees) * 0.45)
        let local = scanHoleInCandidates(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunTarget: frame.overrunTarget,
            minimumVelocity: max(expanded.minimumVelocity, aimedSeed.velocity - vSpan),
            maximumVelocity: min(expanded.maximumVelocity, aimedSeed.velocity + vSpan),
            velocityPointCount: 9,
            minimumDirectionDegrees: max(expanded.minimumDirectionDegrees, aimedSeed.betaDegrees - betaSpan),
            maximumDirectionDegrees: min(expanded.maximumDirectionDegrees, aimedSeed.betaDegrees + betaSpan),
            directionPointCount: 9,
            captureRadius: holeInCaptureRadius,
            searchTier: .verified,
            policy: frame.policy
        )
        if let local, launchPassesCup(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            candidate: local.primary
        ) {
            return local
        }
        return drawableFallback(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            expanded: expanded,
            seed: aimedSeed
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
        var velocity = binarySearchVelocity(
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
        // 홀 평면 조준은 홀을 지나게 한 속도로. 짧은 공의 정지점 좌우를 0으로 맞추지 않는다.
        func aimVelocity(at beta: Double) -> Double {
            min(
                expanded.maximumVelocity,
                max(
                    velocity,
                    binarySearchVelocity(
                        terrain: terrain,
                        greenSpeed: greenSpeed,
                        holeDistance: holeDistance,
                        holeDirectionDegrees: holeDirectionDegrees,
                        holePosition: frame.holePosition,
                        direction: frame.direction,
                        overrunDistance: max(frame.overrunDistance, 0.12),
                        betaDegrees: beta,
                        minimumVelocity: expanded.minimumVelocity,
                        maximumVelocity: expanded.maximumVelocity
                    )
                )
            )
        }
        var beta = binarySearchDirection(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            velocity: aimVelocity(at: 0),
            minimumDirectionDegrees: expanded.minimumDirectionDegrees,
            maximumDirectionDegrees: expanded.maximumDirectionDegrees
        )
        velocity = binarySearchVelocity(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunDistance: frame.overrunDistance,
            betaDegrees: beta,
            minimumVelocity: expanded.minimumVelocity,
            maximumVelocity: expanded.maximumVelocity
        )
        beta = binarySearchDirection(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            velocity: aimVelocity(at: beta),
            minimumDirectionDegrees: expanded.minimumDirectionDegrees,
            maximumDirectionDegrees: expanded.maximumDirectionDegrees
        )
        velocity = binarySearchVelocity(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunDistance: frame.overrunDistance,
            betaDegrees: beta,
            minimumVelocity: expanded.minimumVelocity,
            maximumVelocity: expanded.maximumVelocity
        )
        beta = binarySearchDirection(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            velocity: velocity,
            minimumDirectionDegrees: expanded.minimumDirectionDegrees,
            maximumDirectionDegrees: expanded.maximumDirectionDegrees
        )
        velocity = binarySearchVelocity(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            overrunDistance: frame.overrunDistance,
            betaDegrees: beta,
            minimumVelocity: expanded.minimumVelocity,
            maximumVelocity: expanded.maximumVelocity
        )
        return ShootingSeed(velocity: velocity, betaDegrees: beta)
    }

    /// 5.4cm 홀인 격자가 비어도, 같은 물리로 108mm 컵 안을 지난 뒤 홀 뒤 목표까지 올린 추정 궤적을 그린다.
    /// 컵 옆을 스치는 선은 그리지 않는다.
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
        var resolved = seed ?? shootingSeed(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            expanded: expanded
        )
        func approach(velocity: Double, beta: Double) -> Double {
            let geometry = closestApproachToHole(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: frame.holePosition,
                direction: frame.direction,
                velocity: velocity,
                betaDegrees: beta
            )
            return geometry.reached ? geometry.closest : .greatestFiniteMagnitude
        }
        if approach(velocity: resolved.velocity, beta: resolved.betaDegrees) > displayCupPassRadius {
            let aimVelocity = binarySearchVelocity(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: frame.holePosition,
                direction: frame.direction,
                overrunDistance: max(frame.overrunDistance, 0.12),
                betaDegrees: resolved.betaDegrees,
                minimumVelocity: expanded.minimumVelocity,
                maximumVelocity: expanded.maximumVelocity
            )
            resolved.betaDegrees = binarySearchDirection(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: frame.holePosition,
                direction: frame.direction,
                velocity: aimVelocity,
                minimumDirectionDegrees: expanded.minimumDirectionDegrees,
                maximumDirectionDegrees: expanded.maximumDirectionDegrees
            )
            resolved.velocity = binarySearchVelocity(
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
            resolved.betaDegrees = binarySearchDirection(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: frame.holePosition,
                direction: frame.direction,
                velocity: resolved.velocity,
                minimumDirectionDegrees: expanded.minimumDirectionDegrees,
                maximumDirectionDegrees: expanded.maximumDirectionDegrees
            )
            resolved.velocity = binarySearchVelocity(
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
        }
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
            (expanded.maximumVelocity, resolved.betaDegrees, .proximityEstimate)
        ]
        var best: RankedPuttCandidate?
        var bestClosest = Double.greatestFiniteMagnitude
        var bestInBand = false
        var bestPassesCup = false
        var bestTier: CandidateSearchTier = .proximityEstimate
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
            let geom = closestApproachToHole(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: frame.holePosition,
                direction: frame.direction,
                velocity: velocity,
                betaDegrees: beta
            )
            let closest = geom.reached ? geom.closest : Double.greatestFiniteMagnitude
            let inBand = frame.policy.contains(ranked.actualOverrunDistance)
            let passesCup = geom.reached && closest <= displayCupPassRadius
            if passesCup && inBand {
                return CandidateSelectionResult(
                    allCandidates: [ranked],
                    primary: ranked,
                    secondary: ranked,
                    overrunTarget: frame.overrunTarget,
                    usedRelaxedCaptureRadius: false,
                    searchTier: tier,
                    overrunPolicy: frame.policy
                )
            }
            let better: Bool
            if best == nil {
                better = true
            } else if passesCup != bestPassesCup {
                better = passesCup
            } else if inBand != bestInBand {
                better = inBand
            } else {
                better = closest < bestClosest
            }
            if better {
                best = ranked
                bestClosest = closest
                bestInBand = inBand
                bestPassesCup = passesCup
                bestTier = tier
            }
        }
        if bestPassesCup, let best {
            return CandidateSelectionResult(
                allCandidates: [best],
                primary: best,
                secondary: best,
                overrunTarget: frame.overrunTarget,
                usedRelaxedCaptureRadius: false,
                searchTier: bestTier,
                overrunPolicy: frame.policy
            )
        }
        resolved = aimThroughCup(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            expanded: expanded,
            seed: resolved
        )
        if approach(velocity: resolved.velocity, beta: resolved.betaDegrees) <= displayCupPassRadius,
           let ranked = rankedLaunch(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            velocity: resolved.velocity,
            betaDegrees: resolved.betaDegrees,
            tier: .proximityEstimate,
            requireReachHole: true
           ) {
            return CandidateSelectionResult(
                allCandidates: [ranked],
                primary: ranked,
                secondary: ranked,
                overrunTarget: frame.overrunTarget,
                usedRelaxedCaptureRadius: false,
                searchTier: .proximityEstimate,
                overrunPolicy: frame.policy
            )
        }
        return syntheticStraightSelection(frame: frame, holeDistance: holeDistance)
    }

    private static func launchPassesCup<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        frame: SearchFrame,
        candidate: RankedPuttCandidate?
    ) -> Bool {
        guard let candidate else { return false }
        let geometry = closestApproachToHole(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            velocity: candidate.candidate.initialVelocity,
            betaDegrees: candidate.candidate.directionDegrees
        )
        return geometry.reached && geometry.closest <= displayCupPassRadius
    }

    /// 오버런보다 컵 통과를 우선. 컵을 못 뚫는 추정 선은 내보내지 않는다.
    private static func aimThroughCup<Terrain: TerrainField>(
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
        seed: ShootingSeed
    ) -> ShootingSeed {
        func approachGeometry(_ velocity: Double, _ beta: Double) -> (lateral: Double, reached: Bool, closest: Double) {
            closestApproachToHole(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: frame.holePosition,
                direction: frame.direction,
                velocity: velocity,
                betaDegrees: beta
            )
        }
        func approach(_ velocity: Double, _ beta: Double) -> Double {
            let geometry = approachGeometry(velocity, beta)
            return geometry.reached ? geometry.closest : .greatestFiniteMagnitude
        }
        func direction(at velocity: Double) -> Double {
            binarySearchDirection(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: frame.holePosition,
                direction: frame.direction,
                velocity: velocity,
                minimumDirectionDegrees: expanded.minimumDirectionDegrees,
                maximumDirectionDegrees: expanded.maximumDirectionDegrees
            )
        }
        func speed(at beta: Double, overrun: Double) -> Double {
            binarySearchVelocity(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: frame.holePosition,
                direction: frame.direction,
                overrunDistance: overrun,
                betaDegrees: beta,
                minimumVelocity: expanded.minimumVelocity,
                maximumVelocity: expanded.maximumVelocity
            )
        }
        let coastOverrun = max(frame.overrunDistance, preferredOverrunMeters)
        var velocity = max(seed.velocity, speed(at: seed.betaDegrees, overrun: coastOverrun))
        var beta = denseCupBeta(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            frame: frame,
            expanded: expanded,
            velocity: velocity,
            hint: seed.betaDegrees
        )
        var closest = approach(velocity, beta)
        if closest > displayCupPassRadius {
            velocity = expanded.maximumVelocity
            beta = denseCupBeta(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                frame: frame,
                expanded: expanded,
                velocity: velocity,
                hint: beta
            )
            closest = approach(velocity, beta)
        }
        guard closest <= displayCupPassRadius else {
            return ShootingSeed(velocity: velocity, betaDegrees: beta)
        }
        let fittedVelocity = speed(at: beta, overrun: frame.overrunDistance)
        let fittedBeta = direction(at: fittedVelocity)
        if approach(fittedVelocity, fittedBeta) <= displayCupPassRadius {
            return ShootingSeed(velocity: fittedVelocity, betaDegrees: fittedBeta)
        }
        return ShootingSeed(velocity: velocity, betaDegrees: beta)
    }

    private static func denseCupBeta<Terrain: TerrainField>(
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
        velocity: Double,
        hint: Double
    ) -> Double {
        let span = expanded.maximumDirectionDegrees - expanded.minimumDirectionDegrees
        let count = 21
        var bestBeta = hint
        var bestClosest = Double.greatestFiniteMagnitude
        for index in 0..<count {
            let t = Double(index) / Double(count - 1)
            let beta = expanded.minimumDirectionDegrees + t * span
            let geometry = closestApproachToHole(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: frame.holePosition,
                direction: frame.direction,
                velocity: velocity,
                betaDegrees: beta
            )
            let closest = geometry.reached ? geometry.closest : .greatestFiniteMagnitude
            if closest < bestClosest {
                bestClosest = closest
                bestBeta = beta
            }
        }
        return binarySearchDirection(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            holePosition: frame.holePosition,
            direction: frame.direction,
            velocity: velocity,
            minimumDirectionDegrees: max(expanded.minimumDirectionDegrees, bestBeta - 6),
            maximumDirectionDegrees: min(expanded.maximumDirectionDegrees, bestBeta + 6)
        )
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
            searchTier: .flatHeuristic,
            overrunPolicy: frame.policy
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
        let captured = searchSimulate(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            velocity: velocity,
            betaDegrees: betaDegrees,
            ignoreCapture: false
        )
        let overrun = searchSimulate(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            velocity: velocity,
            betaDegrees: betaDegrees,
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

    /// 홀을 지날 때의 좌우 미스. 정지점 좌우가 아니다(휘는 퍼트에서 컵을 놓친다).
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
        let coarseCount = 11
        var samples: [(beta: Double, lateral: Double, reached: Bool, closest: Double)] = []
        samples.reserveCapacity(coarseCount)
        for index in 0..<coarseCount {
            let t = Double(index) / Double(coarseCount - 1)
            let beta = minimumDirectionDegrees
                + t * (maximumDirectionDegrees - minimumDirectionDegrees)
            let probe = closestApproachToHole(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: holePosition,
                direction: direction,
                velocity: velocity,
                betaDegrees: beta
            )
            samples.append((beta, probe.lateral, probe.reached, probe.closest))
        }

        let nearest = samples.min(by: { $0.closest < $1.closest })
        var lo = max(minimumDirectionDegrees, (nearest?.beta ?? 0) - 8)
        var hi = min(maximumDirectionDegrees, (nearest?.beta ?? 0) + 8)

        var signLo: Double?
        var signHi: Double?
        if let nearest {
            for index in 0..<(samples.count - 1) {
                let a = samples[index]
                let b = samples[index + 1]
                guard a.reached, b.reached, a.lateral * b.lateral <= 0 else { continue }
                let midBeta = 0.5 * (a.beta + b.beta)
                guard abs(midBeta - nearest.beta) <= 10 else { continue }
                if abs(a.lateral) < 1e-4 {
                    return a.beta
                }
                signLo = a.beta
                signHi = b.beta
                break
            }
        }
        if let signLo, let signHi, signHi >= lo - 1e-9, signLo <= hi + 1e-9 {
            lo = max(lo, signLo)
            hi = min(hi, signHi)
            var best = 0.5 * (lo + hi)
            for _ in 0..<12 {
                let mid = 0.5 * (lo + hi)
                let probe = closestApproachToHole(
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
                if !probe.reached {
                    if mid > 0 { hi = mid } else { lo = mid }
                    continue
                }
                if probe.lateral > 0 {
                    hi = mid
                } else {
                    lo = mid
                }
            }
            return best
        }

        var bestBeta = nearest?.beta ?? 0
        var bestClosest = nearest?.closest ?? Double.greatestFiniteMagnitude
        for _ in 0..<10 {
            let third = (hi - lo) / 3
            guard third > 0.05 else { break }
            let m1 = lo + third
            let m2 = hi - third
            let c1 = closestApproachToHole(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: holePosition,
                direction: direction,
                velocity: velocity,
                betaDegrees: m1
            )
            let c2 = closestApproachToHole(
                terrain: terrain,
                greenSpeed: greenSpeed,
                holeDistance: holeDistance,
                holeDirectionDegrees: holeDirectionDegrees,
                holePosition: holePosition,
                direction: direction,
                velocity: velocity,
                betaDegrees: m2
            )
            if c1.closest < bestClosest {
                bestClosest = c1.closest
                bestBeta = m1
            }
            if c2.closest < bestClosest {
                bestClosest = c2.closest
                bestBeta = m2
            }
            if c1.closest < c2.closest {
                hi = m2
            } else {
                lo = m1
            }
        }
        return bestBeta
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
        let coast = searchSimulate(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            velocity: velocity,
            betaDegrees: betaDegrees,
            ignoreCapture: true
        )
        let dx = coast.finalPosition.x - holePosition.x
        let dy = coast.finalPosition.y - holePosition.y
        return dx * direction.x + dy * direction.y + holeDistance
    }

    private static func closestApproachToHole<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double,
        holePosition: PuttVector2,
        direction: PuttVector2,
        velocity: Double,
        betaDegrees: Double
    ) -> (lateral: Double, reached: Bool, closest: Double) {
        let coast = searchSimulate(
            terrain: terrain,
            greenSpeed: greenSpeed,
            holeDistance: holeDistance,
            holeDirectionDegrees: holeDirectionDegrees,
            velocity: velocity,
            betaDegrees: betaDegrees,
            ignoreCapture: true,
            recordTrajectory: true
        )
        var positions = coast.trajectory.map(\.position)
        if positions.last.map({ $0 != coast.finalPosition }) ?? true {
            positions.append(coast.finalPosition)
        }
        return holeAimGeometry(
            positions: positions,
            holePosition: holePosition,
            direction: direction,
            holeDistance: holeDistance
        )
    }

    private static func holeAimGeometry(
        positions: [PuttVector2],
        holePosition: PuttVector2,
        direction: PuttVector2,
        holeDistance: Double
    ) -> (lateral: Double, reached: Bool, closest: Double) {
        let right = PuttVector2(x: direction.y, y: -direction.x)
        func along(_ point: PuttVector2) -> Double {
            point.x * direction.x + point.y * direction.y
        }
        func lateral(_ point: PuttVector2) -> Double {
            (point.x - holePosition.x) * right.x + (point.y - holePosition.y) * right.y
        }
        func distance(_ point: PuttVector2) -> Double {
            hypot(point.x - holePosition.x, point.y - holePosition.y)
        }

        var closest = Double.greatestFiniteMagnitude
        var closestLateral = 0.0
        var previous: PuttVector2?
        for point in positions {
            let currentDistance = distance(point)
            if currentDistance < closest {
                closest = currentDistance
                closestLateral = lateral(point)
            }
            if let previous {
                let along0 = along(previous)
                let along1 = along(point)
                if along0 <= holeDistance && along1 >= holeDistance {
                    let span = max(along1 - along0, 1e-12)
                    let t = (holeDistance - along0) / span
                    let crossed = PuttVector2(
                        x: previous.x + t * (point.x - previous.x),
                        y: previous.y + t * (point.y - previous.y)
                    )
                    return (
                        lateral(crossed),
                        true,
                        min(closest, distance(crossed))
                    )
                }
            }
            previous = point
        }
        return (closestLateral, false, closest)
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
