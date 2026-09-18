import Foundation

/// 홀 뒤 정지 목표. 평지·오르막은 0.34–0.44m, 내리막·옆경사는 줄인다.
public struct ServiceOverrunPolicy: Sendable, Equatable {
    public var preferredMeters: Double
    public var minMeters: Double
    public var maxMeters: Double
    /// 진행 방향 내리막 경사(%). 오르막은 0.
    public var alongDownhillPercent: Double
    /// 횡경사 절대값(%).
    public var crossSlopePercent: Double
    /// 홀 뒤에 공이 서지 못하는 한계 경사.
    public var isRestLimit: Bool

    public init(
        preferredMeters: Double,
        minMeters: Double,
        maxMeters: Double,
        alongDownhillPercent: Double,
        crossSlopePercent: Double,
        isRestLimit: Bool
    ) {
        self.preferredMeters = preferredMeters
        self.minMeters = minMeters
        self.maxMeters = maxMeters
        self.alongDownhillPercent = alongDownhillPercent
        self.crossSlopePercent = crossSlopePercent
        self.isRestLimit = isRestLimit
    }

    public static let flat = ServiceOverrunPolicy(
        preferredMeters: CandidateSelector.preferredOverrunMeters,
        minMeters: CandidateSelector.serviceOverrunMinMeters,
        maxMeters: CandidateSelector.serviceOverrunMaxMeters,
        alongDownhillPercent: 0,
        crossSlopePercent: 0,
        isRestLimit: false
    )

    public func contains(_ meters: Double) -> Bool {
        meters + 1e-9 >= minMeters && meters - 1e-9 <= maxMeters
    }

    /// 호출부가 목표 거리를 직접 줄 때(테스트·시뮬레이터).
    public static func targeting(_ meters: Double) -> ServiceOverrunPolicy {
        if abs(meters - CandidateSelector.preferredOverrunMeters) < 1e-9 {
            return .flat
        }
        let preferred = max(0, meters)
        if preferred < 1e-6 {
            return restLimit(alongDownhillPercent: 0, crossSlopePercent: 0)
        }
        return ServiceOverrunPolicy(
            preferredMeters: preferred,
            minMeters: max(0, preferred - bandHalfWidthMeters),
            maxMeters: preferred + bandHalfWidthMeters,
            alongDownhillPercent: 0,
            crossSlopePercent: 0,
            isRestLimit: false
        )
    }

    public static func make<Terrain: TerrainField>(
        terrain: Terrain,
        holeDistance: Double,
        holeDirectionDegrees: Double = 0,
        ballLocal: PuttVector2 = .zero,
        holeLocal: PuttVector2? = nil
    ) -> ServiceOverrunPolicy {
        let holeBeta = holeDirectionDegrees * .pi / 180.0
        let hole = holeLocal ?? PuttVector2(
            x: holeDistance * sin(holeBeta),
            y: holeDistance * cos(holeBeta)
        )
        let dx = hole.x - ballLocal.x
        let dy = hole.y - ballLocal.y
        let distance = max(hypot(dx, dy), 1e-6)
        let dirX = dx / distance
        let dirY = dy / distance
        let rightX = dirY
        let rightY = -dirX

        let heightDelta =
            terrain.height(at: hole) - terrain.height(at: ballLocal)
        let alongFromDrop = max(0, -heightDelta / distance * 100)

        var alongGrad = 0.0
        var crossGrad = 0.0
        let samples = [0.25, 0.5, 0.75, 1.0]
        for t in samples {
            let point = PuttVector2(
                x: ballLocal.x + t * dx,
                y: ballLocal.y + t * dy
            )
            let gradient = terrain.gradient(at: point)
            alongGrad += max(0, -(gradient.x * dirX + gradient.y * dirY))
            crossGrad += abs(gradient.x * rightX + gradient.y * rightY)
        }
        let sampleCount = Double(samples.count)
        let alongPercent = max(alongFromDrop, alongGrad / sampleCount * 100)
        let crossPercent = crossGrad / sampleCount * 100

        if alongPercent < flatAlongPercent, crossPercent < flatCrossPercent {
            return .flat
        }

        let preferred = min(
            CandidateSelector.preferredOverrunMeters,
            max(
                0,
                CandidateSelector.preferredOverrunMeters
                    - alongWeight * alongPercent
                    - crossWeight * crossPercent
            )
        )
        if preferred < 1e-6 {
            return restLimit(
                alongDownhillPercent: alongPercent,
                crossSlopePercent: crossPercent
            )
        }
        return ServiceOverrunPolicy(
            preferredMeters: preferred,
            minMeters: max(0, preferred - bandHalfWidthMeters),
            maxMeters: preferred + bandHalfWidthMeters,
            alongDownhillPercent: alongPercent,
            crossSlopePercent: crossPercent,
            isRestLimit: false
        )
    }

    private static func restLimit(
        alongDownhillPercent: Double,
        crossSlopePercent: Double
    ) -> ServiceOverrunPolicy {
        ServiceOverrunPolicy(
            preferredMeters: 0,
            minMeters: 0,
            maxMeters: restLimitMaxMeters,
            alongDownhillPercent: alongDownhillPercent,
            crossSlopePercent: crossSlopePercent,
            isRestLimit: true
        )
    }

    private static let alongWeight = 0.06
    private static let crossWeight = 0.04
    private static let bandHalfWidthMeters = 0.05
    private static let restLimitMaxMeters = 0.08
    private static let flatAlongPercent = 0.35
    private static let flatCrossPercent = 0.5
}
