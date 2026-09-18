import Foundation

/// 게이트 5.5 모드 1·2가 공유하는 지형 컨텍스트.
/// 직접 격자 / `.grnh` / LiDAR 파이프라인 결과를 동일한 물리 경계로 묶는다.
public struct Gate55TerrainContext: Sendable, Equatable {
    public var field: HeightMapTerrainField
    public var holeDistance: Double
    public var ballLocal: PuttVector2
    public var holeLocal: PuttVector2
    /// AR 월드 재투영용. LiDAR 스캔에서만 채워진다.
    public var scanTransform: ScanCoordinateTransform?
    public var startPose: ScanPose?
    public var holePose: ScanPose?

    public init(
        field: HeightMapTerrainField,
        holeDistance: Double,
        ballLocal: PuttVector2 = .zero,
        holeLocal: PuttVector2? = nil,
        scanTransform: ScanCoordinateTransform? = nil,
        startPose: ScanPose? = nil,
        holePose: ScanPose? = nil
    ) {
        self.field = field
        self.holeDistance = holeDistance
        self.ballLocal = ballLocal
        self.holeLocal = holeLocal ?? PuttVector2(x: 0, y: holeDistance)
        self.scanTransform = scanTransform
        self.startPose = startPose
        self.holePose = holePose
    }
}

/// 모드 1: 임의의 v0·β로 물리엔진을 순방향으로 굴린 결과.
public struct Gate55ForwardResult: Sendable, Equatable {
    public var initialVelocity: Double
    public var directionDegrees: Double
    public var stopPosition: PuttVector2
    public var trajectory: [TrajectorySample]
    public var ballHoleIf: Bool
    public var ballStopIf: Bool
    public var ballPassOverHoleIf: Bool
    public var arcLength: Double

    public init(
        initialVelocity: Double,
        directionDegrees: Double,
        stopPosition: PuttVector2,
        trajectory: [TrajectorySample],
        ballHoleIf: Bool,
        ballStopIf: Bool,
        ballPassOverHoleIf: Bool,
        arcLength: Double
    ) {
        self.initialVelocity = initialVelocity
        self.directionDegrees = directionDegrees
        self.stopPosition = stopPosition
        self.trajectory = trajectory
        self.ballHoleIf = ballHoleIf
        self.ballStopIf = ballStopIf
        self.ballPassOverHoleIf = ballPassOverHoleIf
        self.arcLength = arcLength
    }
}

/// 모드 2: CandidateSelector 1순위 + 스크린골프식 안내값 + Speed Corridor.
public struct Gate55Recommendation: Sendable, Equatable {
    public var horizontalDistance: Double
    public var flatEquivalentDistance: Double
    public var distanceAdjustment: Double
    public var elevationDelta: Double
    public var initialVelocity: Double
    public var directionDegrees: Double
    public var stopPosition: PuttVector2
    /// 현재 선택 후보의 실제 오버런 거리(홀 지나 정지, m).
    public var overrunDistance: Double
    public var usedRelaxedCaptureRadius: Bool
    public var searchTier: CandidateSearchTier
    public var candidateCount: Int
    public var trajectory: [TrajectorySample]
    public var primary: RankedPuttCandidate?
    /// 홀 뒤 정지 후보. 평지는 0.34–0.44m, 내리막·옆경사는 `overrunPolicy` 밴드.
    public var corridorCandidates: [RankedPuttCandidate]
    /// `corridorCandidates`에서 현재 오버런 목표에 가장 가까운 인덱스.
    public var defaultCorridorIndex: Int
    public var overrunPolicy: ServiceOverrunPolicy

    public init(
        horizontalDistance: Double,
        flatEquivalentDistance: Double,
        distanceAdjustment: Double,
        elevationDelta: Double,
        initialVelocity: Double,
        directionDegrees: Double,
        stopPosition: PuttVector2,
        overrunDistance: Double,
        usedRelaxedCaptureRadius: Bool,
        searchTier: CandidateSearchTier = .verified,
        candidateCount: Int,
        trajectory: [TrajectorySample],
        primary: RankedPuttCandidate?,
        corridorCandidates: [RankedPuttCandidate] = [],
        defaultCorridorIndex: Int = 0,
        overrunPolicy: ServiceOverrunPolicy = .flat
    ) {
        self.horizontalDistance = horizontalDistance
        self.flatEquivalentDistance = flatEquivalentDistance
        self.distanceAdjustment = distanceAdjustment
        self.elevationDelta = elevationDelta
        self.initialVelocity = initialVelocity
        self.directionDegrees = directionDegrees
        self.stopPosition = stopPosition
        self.overrunDistance = overrunDistance
        self.usedRelaxedCaptureRadius = usedRelaxedCaptureRadius
        self.searchTier = searchTier
        self.candidateCount = candidateCount
        self.trajectory = trajectory
        self.primary = primary
        self.corridorCandidates = corridorCandidates
        self.defaultCorridorIndex = defaultCorridorIndex
        self.overrunPolicy = overrunPolicy
    }

    public var strokeGuidance: String {
        String(format: "%.1fm 치는 느낌으로 스트로크하세요", flatEquivalentDistance)
    }
}

public enum Gate55Validation {
    /// UI·「치는 느낌」용 평지환산에 쓰는 기준 그린스피드(m).
    /// 추천 v₀는 사용자 `greenSpeed`로 구하지만, 표시 거리는 이 값으로 고정해야
    /// 그린스피드를 낮출 때(느린 그린 → 더 세게) 안내 거리가 길어지는 직관과 맞는다.
    public static let flatDisplayReferenceGreenSpeed = 2.5

    // MARK: - Terrain adapters

    /// 직접 실측 격자 → 컨텍스트. 값은 이미 로컬(+Y=볼→홀) 좌표계라고 가정한다.
    public static func contextFromMeasuredGrid(
        cellSize: Double,
        originX: Double,
        originY: Double,
        width: Int,
        height: Int,
        heights: [Double],
        holeDistance: Double,
        sigma: Double = 0
    ) throws -> Gate55TerrainContext {
        precondition(heights.count == width * height)
        let measured = Array(repeating: true, count: heights.count)
        let interpolated = Array(repeating: false, count: heights.count)
        var map = HeightMap(
            cellSize: cellSize,
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            values: heights,
            measuredMask: measured,
            interpolatedMask: interpolated
        )
        if sigma > 0 {
            map = GaussianSmoother.smooth(map, sigma: sigma)
        }
        let gradient = GradientFieldBuilder.build(from: map)
        let field = HeightMapTerrainField(heightMap: map, gradientField: gradient)
        return Gate55TerrainContext(field: field, holeDistance: holeDistance)
    }

    /// 야디지 `.grnh` + 볼·홀 월드 좌표.
    public static func contextFromGreen(
        _ green: GreenHeightmap,
        ballWorld: PuttVector2,
        holeWorld: PuttVector2,
        sigma: Double = 1.5
    ) throws -> Gate55TerrainContext {
        let (alignment, field) = try GreenAligner.makeTerrainField(
            from: green,
            ballWorld: ballWorld,
            holeWorld: holeWorld,
            sigma: sigma
        )
        return Gate55TerrainContext(
            field: field,
            holeDistance: alignment.holeDistance,
            ballLocal: .zero,
            holeLocal: PuttVector2(x: 0, y: alignment.holeDistance)
        )
    }

    /// LiDAR 파이프라인 결과 + pose 메타데이터.
    public static func contextFromScan(
        result: TerrainPipelineResult,
        startPose: ScanPose,
        holePose: ScanPose
    ) throws -> Gate55TerrainContext {
        let transform = try ScanCoordinateTransform(ball: startPose, hole: holePose)
        let holeDistance = hypot(
            holePose.worldX - startPose.worldX,
            holePose.worldZ - startPose.worldZ
        )
        let field = HeightMapTerrainField(
            heightMap: result.smoothed,
            gradientField: result.gradient
        )
        return Gate55TerrainContext(
            field: field,
            holeDistance: holeDistance,
            ballLocal: .zero,
            holeLocal: PuttVector2(x: 0, y: holeDistance),
            scanTransform: transform,
            startPose: startPose,
            holePose: holePose
        )
    }

    // MARK: - Mode 1 / Mode 2

    /// 모드 1: 지형 + v0·β → 예측 궤적·정지위치.
    /// 궤적은 홀 캡처에서 끊기지 않고 오버런 정지까지 표시한다.
    public static func runForward(
        context: Gate55TerrainContext,
        greenSpeed: Double,
        initialVelocity: Double,
        directionDegrees: Double,
        recordTrajectory: Bool = true
    ) -> Gate55ForwardResult {
        let configuration = MultibreakPuttConfiguration(
            greenSpeed: greenSpeed,
            initialVelocity: initialVelocity,
            initialDirectionDegrees: directionDegrees,
            holeDistance: context.holeDistance,
            holeDirectionDegrees: 0
        )
        let capture = MultibreakPuttPhysics.simulate(
            configuration: configuration,
            terrain: context.field,
            recordTrajectory: false
        )
        let display: FlatPuttResult
        if recordTrajectory {
            display = MultibreakPuttPhysics.simulate(
                configuration: configuration,
                terrain: context.field,
                recordTrajectory: true,
                ignoreCapture: true
            )
        } else {
            display = capture
        }
        return Gate55ForwardResult(
            initialVelocity: initialVelocity,
            directionDegrees: directionDegrees,
            stopPosition: display.finalPosition,
            trajectory: display.trajectory,
            ballHoleIf: capture.ballHoleIf == 1,
            ballStopIf: display.ballStopIf == 1,
            ballPassOverHoleIf: capture.ballPassOverHoleIf == 1,
            arcLength: display.arcLength
        )
    }

    /// 모드 2: CandidateSelector 1순위 + 평지환산·고도차.
    /// `velocityPointCount` / `directionPointCount` 로 탐색 해상도를 줄여 발열·지연을 완화할 수 있다.
    public static func recommend(
        context: Gate55TerrainContext,
        greenSpeed: Double,
        velocityPointCount: Int = 130,
        directionPointCount: Int = 130,
        searchStrategy: CandidateSearchStrategy = .grid
    ) -> Gate55Recommendation {
        let selection = CandidateSelector.select(
            terrain: context.field,
            greenSpeed: greenSpeed,
            holeDistance: context.holeDistance,
            holeDirectionDegrees: 0,
            velocityPointCount: velocityPointCount,
            directionPointCount: directionPointCount,
            strategy: searchStrategy
        )
        let horizontal = hypot(
            context.holeLocal.x - context.ballLocal.x,
            context.holeLocal.y - context.ballLocal.y
        )
        let elevationDelta =
            context.field.height(at: context.holeLocal)
            - context.field.height(at: context.ballLocal)

        // 슬라이더: 짧음(정책 하한) → 조금 지남(정책 상한).
        let corridorPolicy = selection.overrunPolicy
        let corridor = selection.allCandidates
            .filter {
                corridorPolicy.contains($0.actualOverrunDistance)
            }
            .sorted {
                $0.actualOverrunDistance < $1.actualOverrunDistance
            }

        let primary: RankedPuttCandidate
        if let selected = selection.primary {
            primary = selected
        } else if let first = corridor.first {
            primary = first
        } else {
            return nearestCalculatedRecommendation(
                context: context,
                greenSpeed: greenSpeed,
                horizontal: horizontal,
                elevationDelta: elevationDelta,
                policy: corridorPolicy
            )
        }

        let defaultIndex = corridor.firstIndex(where: {
            $0.candidate.initialVelocity == primary.candidate.initialVelocity
                && $0.candidate.directionDegrees == primary.candidate.directionDegrees
        }) ?? corridor.indices.min(by: {
            abs(corridor[$0].actualOverrunDistance - corridorPolicy.preferredMeters)
                < abs(corridor[$1].actualOverrunDistance - corridorPolicy.preferredMeters)
        }) ?? 0

        return recommendation(
            context: context,
            greenSpeed: greenSpeed,
            horizontal: horizontal,
            elevationDelta: elevationDelta,
            primary: primary,
            corridor: corridor,
            defaultIndex: defaultIndex,
            searchTier: selection.searchTier,
            usedRelaxed: selection.usedRelaxedCaptureRadius,
            overrunPolicy: corridorPolicy
        )
    }

    /// 5.4cm 홀인이 없어도 같은 물리 엔진으로 홀에 가장 가깝게 굴린 궤적.
    private static func nearestCalculatedRecommendation(
        context: Gate55TerrainContext,
        greenSpeed: Double,
        horizontal: Double,
        elevationDelta: Double,
        policy: ServiceOverrunPolicy
    ) -> Gate55Recommendation {
        let velocity = max(1.2, min(6.0, 1.15 + horizontal * 0.28))
        let forward = runForward(
            context: context,
            greenSpeed: greenSpeed,
            initialVelocity: velocity,
            directionDegrees: 0,
            recordTrajectory: true
        )
        let ranked = RankedPuttCandidate(
            candidate: InitialConditionCandidate(
                initialVelocity: velocity,
                directionDegrees: 0,
                result: FlatPuttResult(
                    trajectory: forward.trajectory,
                    ballStopIf: forward.ballStopIf ? 1 : 0,
                    ballHoleIf: forward.ballHoleIf ? 1 : 0,
                    ballPassOverHoleIf: forward.ballPassOverHoleIf ? 1 : 0,
                    arcLength: forward.arcLength,
                    finalPosition: forward.stopPosition
                )
            ),
            overrunStopPosition: forward.stopPosition,
            distanceToOverrunTarget: hypot(
                forward.stopPosition.x,
                forward.stopPosition.y - horizontal - policy.preferredMeters
            ),
            actualOverrunDistance: max(0, forward.stopPosition.y - horizontal),
            usedRelaxedCaptureRadius: false,
            searchTier: .proximityEstimate
        )
        return recommendation(
            context: context,
            greenSpeed: greenSpeed,
            horizontal: horizontal,
            elevationDelta: elevationDelta,
            primary: ranked,
            corridor: policy.contains(ranked.actualOverrunDistance) ? [ranked] : [],
            defaultIndex: 0,
            searchTier: .proximityEstimate,
            usedRelaxed: false,
            trajectory: forward.trajectory,
            overrunPolicy: policy
        )
    }

    private static func recommendation(
        context: Gate55TerrainContext,
        greenSpeed: Double,
        horizontal: Double,
        elevationDelta: Double,
        primary: RankedPuttCandidate,
        corridor: [RankedPuttCandidate],
        defaultIndex: Int,
        searchTier: CandidateSearchTier,
        usedRelaxed: Bool,
        trajectory: [TrajectorySample]? = nil,
        overrunPolicy: ServiceOverrunPolicy = .flat
    ) -> Gate55Recommendation {
        let flat = flatDisplayEquivalentDistance(
            initialVelocity: primary.candidate.initialVelocity
        )
        let path: [TrajectorySample]
        if let trajectory, trajectory.count >= 2 {
            path = trajectory
        } else {
            path = runForward(
                context: context,
                greenSpeed: greenSpeed,
                initialVelocity: primary.candidate.initialVelocity,
                directionDegrees: primary.candidate.directionDegrees,
                recordTrajectory: true
            ).trajectory
        }
        return Gate55Recommendation(
            horizontalDistance: horizontal,
            flatEquivalentDistance: flat,
            distanceAdjustment: flat - horizontal,
            elevationDelta: elevationDelta,
            initialVelocity: primary.candidate.initialVelocity,
            directionDegrees: primary.candidate.directionDegrees,
            stopPosition: primary.overrunStopPosition,
            overrunDistance: primary.actualOverrunDistance,
            usedRelaxedCaptureRadius: usedRelaxed,
            searchTier: searchTier,
            candidateCount: corridor.count,
            trajectory: path,
            primary: primary,
            corridorCandidates: corridor,
            defaultCorridorIndex: defaultIndex,
            overrunPolicy: overrunPolicy
        )
    }

    /// 평탄 지형에서 |β|만 큰 조준 — LiDAR 노이즈로 보고 경로·스피드 코리도에서 제외.
    public static func isLikelyFlatNoiseAim(
        elevationDelta: Double,
        directionDegrees: Double
    ) -> Bool {
        abs(elevationDelta) < 0.025 && abs(directionDegrees) > 8
    }

    /// 게이트 2 FlatPuttPhysics를 평지(α=0)에서 순방향 실행한 정지 이동거리.
    public static func flatEquivalentDistance(
        initialVelocity: Double,
        greenSpeed: Double
    ) -> Double {
        let flat = FlatPuttPhysics.simulate(
            configuration: FlatPuttConfiguration(
                greenSpeed: greenSpeed,
                slopeDegrees: 0,
                initialVelocity: initialVelocity,
                initialDirectionDegrees: 0,
                holeDistance: 10_000,
                holeDirectionDegrees: 0
            ),
            recordTrajectory: false
        )
        return flat.arcLength
    }

    /// UI에 표시할 평지환산 — 추천 v₀ + `flatDisplayReferenceGreenSpeed`.
    public static func flatDisplayEquivalentDistance(initialVelocity: Double) -> Double {
        flatEquivalentDistance(
            initialVelocity: initialVelocity,
            greenSpeed: flatDisplayReferenceGreenSpeed
        )
    }
}

public extension ScanCoordinateTransform {
    /// 로컬 (x,y) + 상대고도 → AR 월드 (X,Y,Z).
    func world(localX: Double, localY: Double, height: Double = 0) -> (
        worldX: Double,
        worldY: Double,
        worldZ: Double
    ) {
        let worldX = origin.worldX + localX * rightX + localY * forwardX
        let worldZ = origin.worldZ + localX * rightZ + localY * forwardZ
        let worldY = origin.worldY + height
        return (worldX, worldY, worldZ)
    }

    /// β(도) 방향 단위벡터의 AR 월드 수평 성분.
    func aimWorldDirection(betaDegrees: Double) -> (dx: Double, dz: Double) {
        let beta = betaDegrees * .pi / 180
        let localRight = sin(beta)
        let localForward = cos(beta)
        let dx = localRight * rightX + localForward * forwardX
        let dz = localRight * rightZ + localForward * forwardZ
        return (dx, dz)
    }
}

public extension PuttVector2 {
    static let zero = PuttVector2(x: 0, y: 0)
}
