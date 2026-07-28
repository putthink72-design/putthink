import Foundation

public struct PuttVector2: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var magnitude: Double {
        hypot(x, y)
    }
}

public struct PuttAcceleration: Codable, Sendable, Equatable {
    public let ax: Double
    public let ay: Double

    public init(ax: Double, ay: Double) {
        self.ax = ax
        self.ay = ay
    }
}

public enum HoleCaptureResult: String, Codable, Sendable {
    case captured
    case passedOver
    case none
}

public struct TrajectorySample: Codable, Sendable, Equatable {
    public let position: PuttVector2
    public let arcLength: Double
    public let speed: Double

    public init(position: PuttVector2, arcLength: Double, speed: Double) {
        self.position = position
        self.arcLength = arcLength
        self.speed = speed
    }
}

public struct FlatPuttConfiguration: Codable, Sendable, Equatable {
    public var greenSpeed: Double
    public var slopeDegrees: Double
    public var initialVelocity: Double
    public var initialDirectionDegrees: Double
    public var stopVelocity: Double
    public var timeFinal: Double
    public var timeDelta: Double
    public var holeDistance: Double
    public var holeDirectionDegrees: Double

    public init(
        greenSpeed: Double,
        slopeDegrees: Double,
        initialVelocity: Double,
        initialDirectionDegrees: Double,
        stopVelocity: Double = 0.01,
        timeFinal: Double = 20,
        timeDelta: Double = 0.01,
        holeDistance: Double,
        holeDirectionDegrees: Double
    ) {
        self.greenSpeed = greenSpeed
        self.slopeDegrees = slopeDegrees
        self.initialVelocity = initialVelocity
        self.initialDirectionDegrees = initialDirectionDegrees
        self.stopVelocity = stopVelocity
        self.timeFinal = timeFinal
        self.timeDelta = timeDelta
        self.holeDistance = holeDistance
        self.holeDirectionDegrees = holeDirectionDegrees
    }
}

public struct FlatPuttResult: Codable, Sendable, Equatable {
    public var trajectory: [TrajectorySample]
    public var ballStopIf: Int
    public var ballHoleIf: Int
    public var ballPassOverHoleIf: Int
    public var arcLength: Double
    public var finalPosition: PuttVector2
    public var finalVelocity: PuttVector2
    public var ballSpeedForHole: Double
    public var numberOfSteps: Int

    public init(
        trajectory: [TrajectorySample] = [],
        ballStopIf: Int = 0,
        ballHoleIf: Int = 0,
        ballPassOverHoleIf: Int = 0,
        arcLength: Double = 0,
        finalPosition: PuttVector2 = PuttVector2(x: 0, y: 0),
        finalVelocity: PuttVector2 = PuttVector2(x: 0, y: 0),
        ballSpeedForHole: Double = 0,
        numberOfSteps: Int = 0
    ) {
        self.trajectory = trajectory
        self.ballStopIf = ballStopIf
        self.ballHoleIf = ballHoleIf
        self.ballPassOverHoleIf = ballPassOverHoleIf
        self.arcLength = arcLength
        self.finalPosition = finalPosition
        self.finalVelocity = finalVelocity
        self.ballSpeedForHole = ballSpeedForHole
        self.numberOfSteps = numberOfSteps
    }
}

public struct InitialConditionScanConfiguration: Codable, Sendable, Equatable {
    public var greenSpeed: Double
    public var slopeDegrees: Double
    public var minimumVelocity: Double
    public var maximumVelocity: Double
    public var numberOfVelocityScans: Int
    public var minimumDirectionDegrees: Double
    public var maximumDirectionDegrees: Double
    public var numberOfDirectionScans: Int
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
        numberOfVelocityScans: Int,
        minimumDirectionDegrees: Double,
        maximumDirectionDegrees: Double,
        numberOfDirectionScans: Int,
        stopVelocity: Double = 0.01,
        timeFinal: Double = 20,
        timeDelta: Double = 0.01,
        holeDistance: Double,
        holeDirectionDegrees: Double
    ) {
        precondition(numberOfVelocityScans > 0)
        precondition(numberOfDirectionScans > 0)
        self.greenSpeed = greenSpeed
        self.slopeDegrees = slopeDegrees
        self.minimumVelocity = minimumVelocity
        self.maximumVelocity = maximumVelocity
        self.numberOfVelocityScans = numberOfVelocityScans
        self.minimumDirectionDegrees = minimumDirectionDegrees
        self.maximumDirectionDegrees = maximumDirectionDegrees
        self.numberOfDirectionScans = numberOfDirectionScans
        self.stopVelocity = stopVelocity
        self.timeFinal = timeFinal
        self.timeDelta = timeDelta
        self.holeDistance = holeDistance
        self.holeDirectionDegrees = holeDirectionDegrees
    }
}

public struct InitialConditionCandidate: Codable, Sendable, Equatable {
    public let initialVelocity: Double
    public let directionDegrees: Double
    public let result: FlatPuttResult

    public init(initialVelocity: Double, directionDegrees: Double, result: FlatPuttResult) {
        self.initialVelocity = initialVelocity
        self.directionDegrees = directionDegrees
        self.result = result
    }
}

public enum FlatPuttPhysics {
    private static let gravity = 9.8
    private static let holeRadius = 0.054

    /// 원본 Mathematica trajectory01[]의 가속도 블록을 수식 수준에서 그대로 이식한 함수.
    /// 각도 관례는 +Y축 기준이며 beta = atan2(vx, vy)이다.
    public static func computeAcceleration(
        vx: Double,
        vy: Double,
        alpha: Double,
        greenSpeed: Double
    ) -> PuttAcceleration {
        let contactPosition = (7.0 / 10.0) * (1.83 * 1.83 / gravity) / greenSpeed
        let beta = atan2(vx, vy)
        let temp1 = contactPosition * cos(alpha) * sin(beta) - (2.0 / 5.0) * sin(alpha)
        let temp2 = contactPosition * cos(alpha) * cos(beta)
        let piValue = atan2(temp1, temp2)
        let angleMargine = (.pi / 2.0) * 0.01
        let halfPi = Double.pi / 2.0
        let threeHalfPi = 3.0 * Double.pi / 2.0

        let nearVertical =
            (halfPi - angleMargine < piValue && piValue < halfPi + angleMargine)
            || (-halfPi - angleMargine < piValue && piValue < -halfPi + angleMargine)
            || (threeHalfPi - angleMargine < piValue && piValue < threeHalfPi + angleMargine)
            || (-threeHalfPi - angleMargine < piValue && piValue < -threeHalfPi + angleMargine)

        let forceResist: Double
        if nearVertical {
            forceResist = (1.0 / sin(piValue)) * (2.0 * gravity / 7.0)
                * (-sin(alpha) + (5.0 / 2.0) * contactPosition * cos(alpha) * sin(beta))
        } else {
            forceResist = (1.0 / cos(piValue)) * (5.0 * gravity / 7.0)
                * contactPosition * cos(alpha) * cos(beta)
        }

        return PuttAcceleration(
            ax: -gravity * sin(alpha) - forceResist * sin(piValue),
            ay: -forceResist * cos(piValue)
        )
    }

    /// 원본 캡처 블록의 temp 변수 재사용 흐름까지 동일하게 반영한다.
    /// `captureRadius` 기본값은 원본 홀 반경(0.054m). 게이트 5의 3순위 완화 재계산만 다른 값을 넘긴다.
    public static func checkHoleCapture(
        position: PuttVector2,
        velocity: PuttVector2,
        holePosition: PuttVector2,
        alpha: Double,
        beta: Double,
        captureRadius: Double = 0.054
    ) -> HoleCaptureResult {
        let radius = captureRadius > 0 ? captureRadius : holeRadius
        let speed = max(velocity.magnitude, 1e-9)
        let offsetX = position.x - holePosition.x
        let offsetY = position.y - holePosition.y
        let impactParameter = abs(
            (-velocity.y / speed) * offsetX + (velocity.x / speed) * offsetY
        )

        var temp3 = sin(alpha) * sin(beta)
        if abs(1.0 - temp3) < 1e-3 {
            temp3 = 0.999
        }
        let criticalSpeed = (1.63 / sqrt(1.0 - temp3))
            * (1.0 - pow(impactParameter / radius, 2))
        let criticalDistance = abs(
            (velocity.x / speed) * offsetX + (velocity.y / speed) * offsetY
        )
        let intersectsCup = impactParameter < radius && criticalDistance < radius

        if speed < criticalSpeed && intersectsCup {
            return .captured
        }
        return intersectsCup ? .passedOver : .none
    }

    /// 원본의 위치 적분, 판정 순서, Break 시 마지막 상태 미교체 quirk를 보존한다.
    public static func simulate(
        configuration: FlatPuttConfiguration,
        recordTrajectory: Bool = true
    ) -> FlatPuttResult {
        let alpha = configuration.slopeDegrees * .pi / 180.0
        let initialBeta = configuration.initialDirectionDegrees * .pi / 180.0
        let holeBeta = configuration.holeDirectionDegrees * .pi / 180.0
        let holePosition = PuttVector2(
            x: configuration.holeDistance * sin(holeBeta),
            y: configuration.holeDistance * cos(holeBeta)
        )

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

            let acceleration = computeAcceleration(
                vx: velocity1.x,
                vy: velocity1.y,
                alpha: alpha,
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
            let beta2 = atan2(velocity2.x, velocity2.y)
            ballSpeedForHole = max(velocity2.magnitude, 1e-9)

            switch checkHoleCapture(
                position: position2,
                velocity: velocity2,
                holePosition: holePosition,
                alpha: alpha,
                beta: beta2
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

    /// Mathematica Do의 부동소수 누적 순서를 재현한 전수 격자 탐색.
    public static func scanInitialConditions(
        configuration: InitialConditionScanConfiguration
    ) -> [InitialConditionCandidate] {
        var minimumVelocity = configuration.minimumVelocity
        var maximumVelocity = configuration.maximumVelocity
        if minimumVelocity <= 0 || maximumVelocity <= 0 {
            minimumVelocity = 1e-6
            maximumVelocity = abs(maximumVelocity)
        }

        let velocityDelta = (maximumVelocity - minimumVelocity)
            / Double(configuration.numberOfVelocityScans)
        let minimumBeta = configuration.minimumDirectionDegrees * .pi / 180.0
        let maximumBeta = configuration.maximumDirectionDegrees * .pi / 180.0
        let betaDelta = (maximumBeta - minimumBeta)
            / Double(configuration.numberOfDirectionScans)
        let velocityEpsilon = velocityDelta == 0 ? 0 : abs(velocityDelta) * 1e-9
        let betaEpsilon = betaDelta == 0 ? 0 : abs(betaDelta) * 1e-9

        var candidates: [InitialConditionCandidate] = []
        var velocity = minimumVelocity
        while velocity <= maximumVelocity + velocityEpsilon {
            var beta = minimumBeta
            while beta <= maximumBeta + betaEpsilon {
                let betaDegrees = beta * 180.0 / .pi
                let result = simulate(
                    configuration: FlatPuttConfiguration(
                        greenSpeed: configuration.greenSpeed,
                        slopeDegrees: configuration.slopeDegrees,
                        initialVelocity: velocity,
                        initialDirectionDegrees: betaDegrees,
                        stopVelocity: configuration.stopVelocity,
                        timeFinal: configuration.timeFinal,
                        timeDelta: configuration.timeDelta,
                        holeDistance: configuration.holeDistance,
                        holeDirectionDegrees: configuration.holeDirectionDegrees
                    ),
                    recordTrajectory: false
                )
                if result.ballHoleIf == 1 {
                    candidates.append(
                        InitialConditionCandidate(
                            initialVelocity: velocity,
                            directionDegrees: betaDegrees,
                            result: result
                        )
                    )
                }
                if betaDelta == 0 { break }
                beta += betaDelta
            }
            if velocityDelta == 0 { break }
            velocity += velocityDelta
        }
        return candidates
    }
}
