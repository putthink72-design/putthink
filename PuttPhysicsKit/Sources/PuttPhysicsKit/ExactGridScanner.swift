import Foundation

/// 게이트 3 성능 측정용 격자 정의.
///
/// 기존 `InitialConditionScanConfiguration`은 Mathematica 호환을 위해 N개 구간,
/// N+1개 점을 생성한다. 이 타입은 문서의 30×30, 130×130 의미대로 각 축에서
/// 정확히 `pointCount`개의 점을 생성하며 기존 게이트 2 API를 변경하지 않는다.
public struct ExactGridScanConfiguration: Sendable, Equatable {
    public var greenSpeed: Double
    public var slopeDegrees: Double
    public var minimumVelocity: Double
    public var maximumVelocity: Double
    public var velocityPointCount: Int
    public var minimumDirectionDegrees: Double
    public var maximumDirectionDegrees: Double
    public var directionPointCount: Int
    public var stopVelocity: Double
    public var timeFinal: Double
    public var timeDelta: Double
    public var holeDistance: Double
    public var holeDirectionDegrees: Double

    public init(
        greenSpeed: Double,
        slopeDegrees: Double,
        minimumVelocity: Double,
        maximumVelocity: Double,
        velocityPointCount: Int,
        minimumDirectionDegrees: Double,
        maximumDirectionDegrees: Double,
        directionPointCount: Int,
        stopVelocity: Double = 0.01,
        timeFinal: Double = 20,
        timeDelta: Double = 0.01,
        holeDistance: Double,
        holeDirectionDegrees: Double
    ) {
        precondition(velocityPointCount > 0)
        precondition(directionPointCount > 0)
        self.greenSpeed = greenSpeed
        self.slopeDegrees = slopeDegrees
        self.minimumVelocity = minimumVelocity
        self.maximumVelocity = maximumVelocity
        self.velocityPointCount = velocityPointCount
        self.minimumDirectionDegrees = minimumDirectionDegrees
        self.maximumDirectionDegrees = maximumDirectionDegrees
        self.directionPointCount = directionPointCount
        self.stopVelocity = stopVelocity
        self.timeFinal = timeFinal
        self.timeDelta = timeDelta
        self.holeDistance = holeDistance
        self.holeDirectionDegrees = holeDirectionDegrees
    }

    public var combinationCount: Int {
        velocityPointCount * directionPointCount
    }
}

private final class LockedCandidateRows: @unchecked Sendable {
    private var rows: [[InitialConditionCandidate]]
    private let lock = NSLock()

    init(count: Int) {
        rows = Array(repeating: [], count: count)
    }

    func set(_ candidates: [InitialConditionCandidate], at index: Int) {
        lock.lock()
        rows[index] = candidates
        lock.unlock()
    }

    func flattened() -> [InitialConditionCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return rows.flatMap { $0 }
    }
}

public extension FlatPuttPhysics {
    /// 각 축에서 정확히 지정된 개수의 점을 평가하는 직렬 탐색.
    static func scanExactGridSerial(
        configuration: ExactGridScanConfiguration
    ) -> [InitialConditionCandidate] {
        let velocities = exactGridValues(
            minimum: sanitizedMinimumVelocity(configuration),
            maximum: sanitizedMaximumVelocity(configuration),
            count: configuration.velocityPointCount
        )
        let directions = exactGridValues(
            minimum: configuration.minimumDirectionDegrees,
            maximum: configuration.maximumDirectionDegrees,
            count: configuration.directionPointCount
        )

        return velocities.flatMap { velocity in
            candidates(
                velocity: velocity,
                directions: directions,
                configuration: configuration
            )
        }
    }

    /// 속도 행을 독립 작업으로 병렬 계산하고 직렬 탐색과 같은 순서로 반환한다.
    static func scanExactGridParallel(
        configuration: ExactGridScanConfiguration
    ) -> [InitialConditionCandidate] {
        let velocities = exactGridValues(
            minimum: sanitizedMinimumVelocity(configuration),
            maximum: sanitizedMaximumVelocity(configuration),
            count: configuration.velocityPointCount
        )
        let directions = exactGridValues(
            minimum: configuration.minimumDirectionDegrees,
            maximum: configuration.maximumDirectionDegrees,
            count: configuration.directionPointCount
        )
        let rows = LockedCandidateRows(count: velocities.count)

        DispatchQueue.concurrentPerform(iterations: velocities.count) { index in
            rows.set(
                candidates(
                    velocity: velocities[index],
                    directions: directions,
                    configuration: configuration
                ),
                at: index
            )
        }
        return rows.flattened()
    }

    private static func exactGridValues(
        minimum: Double,
        maximum: Double,
        count: Int
    ) -> [Double] {
        guard count > 1 else { return [minimum] }
        let delta = (maximum - minimum) / Double(count - 1)
        return (0..<count).map { index in
            index == count - 1 ? maximum : minimum + Double(index) * delta
        }
    }

    private static func sanitizedMinimumVelocity(
        _ configuration: ExactGridScanConfiguration
    ) -> Double {
        if configuration.minimumVelocity <= 0 || configuration.maximumVelocity <= 0 {
            return 1e-6
        }
        return configuration.minimumVelocity
    }

    private static func sanitizedMaximumVelocity(
        _ configuration: ExactGridScanConfiguration
    ) -> Double {
        if configuration.minimumVelocity <= 0 || configuration.maximumVelocity <= 0 {
            return abs(configuration.maximumVelocity)
        }
        return configuration.maximumVelocity
    }

    private static func candidates(
        velocity: Double,
        directions: [Double],
        configuration: ExactGridScanConfiguration
    ) -> [InitialConditionCandidate] {
        directions.compactMap { direction in
            let result = simulate(
                configuration: FlatPuttConfiguration(
                    greenSpeed: configuration.greenSpeed,
                    slopeDegrees: configuration.slopeDegrees,
                    initialVelocity: velocity,
                    initialDirectionDegrees: direction,
                    stopVelocity: configuration.stopVelocity,
                    timeFinal: configuration.timeFinal,
                    timeDelta: configuration.timeDelta,
                    holeDistance: configuration.holeDistance,
                    holeDirectionDegrees: configuration.holeDirectionDegrees
                ),
                recordTrajectory: false
            )
            guard result.ballHoleIf == 1 else { return nil }
            return InitialConditionCandidate(
                initialVelocity: velocity,
                directionDegrees: direction,
                result: result
            )
        }
    }
}
