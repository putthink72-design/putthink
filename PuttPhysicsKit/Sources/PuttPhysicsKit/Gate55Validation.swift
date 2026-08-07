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
    public var candidateCount: Int
    public var trajectory: [TrajectorySample]
    public var primary: RankedPuttCandidate?
    /// 실제 오버런 거리 오름차순(안전→공격적). 이산 코리도 눈금.
    public var corridorCandidates: [RankedPuttCandidate]
    /// `corridorCandidates`에서 X=0.35m 목표에 가장 가까운(기존 1순위) 인덱스.
    public var defaultCorridorIndex: Int

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
        candidateCount: Int,
        trajectory: [TrajectorySample],
        primary: RankedPuttCandidate?,
        corridorCandidates: [RankedPuttCandidate] = [],
        defaultCorridorIndex: Int = 0
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
        self.candidateCount = candidateCount
        self.trajectory = trajectory
        self.primary = primary
        self.corridorCandidates = corridorCandidates
        self.defaultCorridorIndex = defaultCorridorIndex
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
    public static func runForward(
        context: Gate55TerrainContext,
        greenSpeed: Double,
        initialVelocity: Double,
        directionDegrees: Double,
        recordTrajectory: Bool = true
    ) -> Gate55ForwardResult {
        let result = MultibreakPuttPhysics.simulate(
            configuration: MultibreakPuttConfiguration(
                greenSpeed: greenSpeed,
                initialVelocity: initialVelocity,
                initialDirectionDegrees: directionDegrees,
                holeDistance: context.holeDistance,
                holeDirectionDegrees: 0
            ),
            terrain: context.field,
            recordTrajectory: recordTrajectory
        )
        return Gate55ForwardResult(
            initialVelocity: initialVelocity,
            directionDegrees: directionDegrees,
            stopPosition: result.finalPosition,
            trajectory: result.trajectory,
            ballHoleIf: result.ballHoleIf == 1,
            ballStopIf: result.ballStopIf == 1,
            ballPassOverHoleIf: result.ballPassOverHoleIf == 1,
            arcLength: result.arcLength
        )
    }

    /// 모드 2: CandidateSelector 1순위 + 평지환산·고도차.
    /// `velocityPointCount` / `directionPointCount` 로 탐색 해상도를 줄여 발열·지연을 완화할 수 있다.
    public static func recommend(
        context: Gate55TerrainContext,
        greenSpeed: Double,
        velocityPointCount: Int = 130,
        directionPointCount: Int = 130
    ) -> Gate55Recommendation {
        let selection = CandidateSelector.select(
            terrain: context.field,
            greenSpeed: greenSpeed,
            holeDistance: context.holeDistance,
            holeDirectionDegrees: 0,
            velocityPointCount: velocityPointCount,
            directionPointCount: directionPointCount
        )
        let horizontal = hypot(
            context.holeLocal.x - context.ballLocal.x,
            context.holeLocal.y - context.ballLocal.y
        )
        let elevationDelta =
            context.field.height(at: context.holeLocal)
            - context.field.height(at: context.ballLocal)

        let corridor = selection.allCandidates.sorted {
            $0.actualOverrunDistance < $1.actualOverrunDistance
        }

        guard let primary = selection.primary else {
            return Gate55Recommendation(
                horizontalDistance: horizontal,
                flatEquivalentDistance: 0,
                distanceAdjustment: 0,
                elevationDelta: elevationDelta,
                initialVelocity: 0,
                directionDegrees: 0,
                stopPosition: .zero,
                overrunDistance: 0,
                usedRelaxedCaptureRadius: selection.usedRelaxedCaptureRadius,
                candidateCount: selection.allCandidates.count,
                trajectory: [],
                primary: nil,
                corridorCandidates: corridor,
                defaultCorridorIndex: 0
            )
        }

        let defaultIndex = corridor.firstIndex(where: {
            $0.candidate.initialVelocity == primary.candidate.initialVelocity
                && $0.candidate.directionDegrees == primary.candidate.directionDegrees
        }) ?? 0

        let flat = flatDisplayEquivalentDistance(
            initialVelocity: primary.candidate.initialVelocity
        )
        let forward = runForward(
            context: context,
            greenSpeed: greenSpeed,
            initialVelocity: primary.candidate.initialVelocity,
            directionDegrees: primary.candidate.directionDegrees,
            recordTrajectory: true
        )
        return Gate55Recommendation(
            horizontalDistance: horizontal,
            flatEquivalentDistance: flat,
            distanceAdjustment: flat - horizontal,
            elevationDelta: elevationDelta,
            initialVelocity: primary.candidate.initialVelocity,
            directionDegrees: primary.candidate.directionDegrees,
            stopPosition: primary.overrunStopPosition,
            overrunDistance: primary.actualOverrunDistance,
            usedRelaxedCaptureRadius: selection.usedRelaxedCaptureRadius,
            candidateCount: selection.allCandidates.count,
            trajectory: forward.trajectory,
            primary: primary,
            corridorCandidates: corridor,
            defaultCorridorIndex: defaultIndex
        )
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
