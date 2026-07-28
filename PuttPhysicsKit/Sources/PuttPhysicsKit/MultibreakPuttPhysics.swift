import Foundation

public struct MultibreakPuttConfiguration: Codable, Sendable, Equatable {
    public var greenSpeed: Double
    public var initialVelocity: Double
    public var initialDirectionDegrees: Double
    public var stopVelocity: Double
    public var timeFinal: Double
    public var timeDelta: Double
    public var holeDistance: Double
    public var holeDirectionDegrees: Double

    public init(
        greenSpeed: Double,
        initialVelocity: Double,
        initialDirectionDegrees: Double,
        stopVelocity: Double = 0.01,
        timeFinal: Double = 20,
        timeDelta: Double = 0.01,
        holeDistance: Double,
        holeDirectionDegrees: Double
    ) {
        self.greenSpeed = greenSpeed
        self.initialVelocity = initialVelocity
        self.initialDirectionDegrees = initialDirectionDegrees
        self.stopVelocity = stopVelocity
        self.timeFinal = timeFinal
        self.timeDelta = timeDelta
        self.holeDistance = holeDistance
        self.holeDirectionDegrees = holeDirectionDegrees
    }
}

public enum MultibreakPuttPhysics {
    /// 전역 프레임 속도/가속도를 원본 가속도 축(하강 = 국소 −X)으로 맞추는 회전각.
    ///
    /// `descentAzimuth`는 Y축 기준 하강방위각(하강 단위벡터 = `(sin d, cos d)`).
    /// 원본 `computeAcceleration`은 중력을 국소 −X에 두므로, 국소 (−1, 0)을 회전했을 때
    /// 전역 하강방향과 일치해야 한다:
    /// `rotate((-1,0), ψ) = (-cos ψ, -sin ψ) = (sin d, cos d)`
    /// → `ψ = atan2(-cos d, -sin d)`.
    ///
    /// 이전 식 `d + π/2`는 하강 −X(`d = -π/2`)에서만 우연히 맞고,
    /// 오르막(+Y) 등 다른 방위에서는 중력이 상승 방향으로 뒤집혀
    /// “홀이 높은데 내리막 보정” 모순을 만들었다.
    public static func frameRotation(forDescentAzimuth descentAzimuth: Double) -> Double {
        atan2(-cos(descentAzimuth), -sin(descentAzimuth))
    }

    public static func rotate(_ vector: PuttVector2, by radians: Double) -> PuttVector2 {
        let cosine = cos(radians)
        let sine = sin(radians)
        return PuttVector2(
            x: vector.x * cosine - vector.y * sine,
            y: vector.x * sine + vector.y * cosine
        )
    }

    /// 가속도만 국소 프레임에서 계산하고 전역으로 되돌린다.
    public static func computeGlobalAcceleration(
        velocity: PuttVector2,
        slope: LocalSlope,
        greenSpeed: Double
    ) -> PuttAcceleration {
        let psi = frameRotation(forDescentAzimuth: slope.descentAzimuth)
        let localVelocity = rotate(velocity, by: -psi)
        let localAcceleration = FlatPuttPhysics.computeAcceleration(
            vx: localVelocity.x,
            vy: localVelocity.y,
            alpha: slope.alpha,
            greenSpeed: greenSpeed
        )
        let global = rotate(
            PuttVector2(x: localAcceleration.ax, y: localAcceleration.ay),
            by: psi
        )
        return PuttAcceleration(ax: global.x, ay: global.y)
    }

    /// 홀 부근 국소 하강축 기준으로 잰 진행각 β (캡처 공식용).
    public static func captureBeta(
        velocity: PuttVector2,
        holeSlope: LocalSlope
    ) -> Double {
        let psi = frameRotation(forDescentAzimuth: holeSlope.descentAzimuth)
        let localVelocity = rotate(velocity, by: -psi)
        return atan2(localVelocity.x, localVelocity.y)
    }

    /// 위치 적분·캡처·정지는 전역 프레임, 가속도만 회전 래퍼를 경유한다.
    /// - Parameters:
    ///   - ignoreCapture: true면 캡처를 무시하고 정지까지 적분(오버런 평가용)
    ///   - captureRadius: 캡처 허용 반경. 기본 0.054m, 3순위 완화 시 0.5m
    public static func simulate<Terrain: TerrainField>(
        configuration: MultibreakPuttConfiguration,
        terrain: Terrain,
        recordTrajectory: Bool = true,
        ignoreCapture: Bool = false,
        captureRadius: Double = 0.054
    ) -> FlatPuttResult {
        let initialBeta = configuration.initialDirectionDegrees * .pi / 180.0
        let holeBeta = configuration.holeDirectionDegrees * .pi / 180.0
        let holePosition = PuttVector2(
            x: configuration.holeDistance * sin(holeBeta),
            y: configuration.holeDistance * cos(holeBeta)
        )
        let holeSlope = terrain.localSlope(at: holePosition)

        var position1 = PuttVector2(x: 0, y: 0)
        var velocity1 = PuttVector2(
            x: configuration.initialVelocity * sin(initialBeta),
            y: configuration.initialVelocity * cos(initialBeta)
        )
        var result = FlatPuttResult()
        var arcLength = 0.0
        var ballSpeedForHole = 0.0
        let iterationCount = Int((configuration.timeFinal / configuration.timeDelta).rounded()) + 1

        for _ in 0..<iterationCount {
            result.numberOfSteps += 1
            if recordTrajectory {
                result.trajectory.append(
                    TrajectorySample(
                        position: position1,
                        arcLength: arcLength,
                        speed: velocity1.magnitude
                    )
                )
            }

            let slope = terrain.localSlope(at: position1)
            let acceleration = computeGlobalAcceleration(
                velocity: velocity1,
                slope: slope,
                greenSpeed: configuration.greenSpeed
            )
            let velocity2 = PuttVector2(
                x: velocity1.x + acceleration.ax * configuration.timeDelta,
                y: velocity1.y + acceleration.ay * configuration.timeDelta
            )
            let position2 = PuttVector2(
                x: position1.x + velocity1.x * configuration.timeDelta
                    + 0.5 * acceleration.ax * configuration.timeDelta * configuration.timeDelta,
                y: position1.y + velocity1.y * configuration.timeDelta
                    + 0.5 * acceleration.ay * configuration.timeDelta * configuration.timeDelta
            )
            ballSpeedForHole = max(velocity2.magnitude, 1e-9)
            let betaForCapture = captureBeta(velocity: velocity2, holeSlope: holeSlope)

            if !ignoreCapture {
                switch FlatPuttPhysics.checkHoleCapture(
                    position: position2,
                    velocity: velocity2,
                    holePosition: holePosition,
                    alpha: holeSlope.alpha,
                    beta: betaForCapture,
                    captureRadius: captureRadius
                ) {
                case .captured:
                    result.ballHoleIf = 1
                    break
                case .passedOver:
                    if result.ballPassOverHoleIf == 0 {
                        result.ballPassOverHoleIf = 1
                    }
                case .none:
                    break
                }
                if result.ballHoleIf == 1 {
                    break
                }
            }

            if velocity2.magnitude < configuration.stopVelocity {
                result.ballStopIf = 1
                break
            }

            arcLength += hypot(position2.x - position1.x, position2.y - position1.y)
            position1 = position2
            velocity1 = velocity2
        }

        if result.ballHoleIf == 1 {
            result.ballPassOverHoleIf = 0
            result.ballStopIf = 1
        }
        result.arcLength = arcLength
        result.finalPosition = position1
        result.finalVelocity = velocity1
        result.ballSpeedForHole = ballSpeedForHole
        return result
    }

    /// 정확한 점 개수 격자에서 홀인 후보를 직렬 탐색한다.
    public static func scanExactGridSerial<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double = 0,
        minimumVelocity: Double,
        maximumVelocity: Double,
        velocityPointCount: Int,
        minimumDirectionDegrees: Double,
        maximumDirectionDegrees: Double,
        directionPointCount: Int,
        stopVelocity: Double = 0.01,
        timeFinal: Double = 20,
        timeDelta: Double = 0.01,
        captureRadius: Double = 0.054
    ) -> [InitialConditionCandidate] {
        let velocities = exactValues(
            minimum: minimumVelocity,
            maximum: maximumVelocity,
            count: velocityPointCount
        )
        let directions = exactValues(
            minimum: minimumDirectionDegrees,
            maximum: maximumDirectionDegrees,
            count: directionPointCount
        )
        return velocities.flatMap { velocity in
            directions.compactMap { direction in
                let result = simulate(
                    configuration: MultibreakPuttConfiguration(
                        greenSpeed: greenSpeed,
                        initialVelocity: velocity,
                        initialDirectionDegrees: direction,
                        stopVelocity: stopVelocity,
                        timeFinal: timeFinal,
                        timeDelta: timeDelta,
                        holeDistance: holeDistance,
                        holeDirectionDegrees: holeDirectionDegrees
                    ),
                    terrain: terrain,
                    recordTrajectory: false,
                    captureRadius: captureRadius
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

    /// 속도 행을 독립 작업으로 병렬 계산하고 직렬 탐색과 같은 순서로 반환한다.
    /// 행별로 결과를 모아 합치므로 후보 목록·순서는 `scanExactGridSerial`과 동일하다.
    public static func scanExactGridParallel<Terrain: TerrainField>(
        terrain: Terrain,
        greenSpeed: Double,
        holeDistance: Double,
        holeDirectionDegrees: Double = 0,
        minimumVelocity: Double,
        maximumVelocity: Double,
        velocityPointCount: Int,
        minimumDirectionDegrees: Double,
        maximumDirectionDegrees: Double,
        directionPointCount: Int,
        stopVelocity: Double = 0.01,
        timeFinal: Double = 20,
        timeDelta: Double = 0.01,
        captureRadius: Double = 0.054
    ) -> [InitialConditionCandidate] {
        let velocities = exactValues(
            minimum: minimumVelocity,
            maximum: maximumVelocity,
            count: velocityPointCount
        )
        let directions = exactValues(
            minimum: minimumDirectionDegrees,
            maximum: maximumDirectionDegrees,
            count: directionPointCount
        )
        let rows = LockedMultibreakCandidateRows(count: velocities.count)
        DispatchQueue.concurrentPerform(iterations: velocities.count) { index in
            let velocity = velocities[index]
            let row = directions.compactMap { direction -> InitialConditionCandidate? in
                let result = simulate(
                    configuration: MultibreakPuttConfiguration(
                        greenSpeed: greenSpeed,
                        initialVelocity: velocity,
                        initialDirectionDegrees: direction,
                        stopVelocity: stopVelocity,
                        timeFinal: timeFinal,
                        timeDelta: timeDelta,
                        holeDistance: holeDistance,
                        holeDirectionDegrees: holeDirectionDegrees
                    ),
                    terrain: terrain,
                    recordTrajectory: false,
                    captureRadius: captureRadius
                )
                guard result.ballHoleIf == 1 else { return nil }
                return InitialConditionCandidate(
                    initialVelocity: velocity,
                    directionDegrees: direction,
                    result: result
                )
            }
            rows.set(row, at: index)
        }
        return rows.flattened()
    }

    private static func exactValues(minimum: Double, maximum: Double, count: Int) -> [Double] {
        guard count > 1 else { return [minimum] }
        let delta = (maximum - minimum) / Double(count - 1)
        return (0..<count).map { index in
            index == count - 1 ? maximum : minimum + Double(index) * delta
        }
    }
}

private final class LockedMultibreakCandidateRows: @unchecked Sendable {
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
