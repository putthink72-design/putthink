import ARKit
import Foundation
import PuttPhysicsKit
import simd

/// ARKit sceneDepth → ScanCoverage 순수 코어 브리지.
/// 배경 큐에서 샘플링하고, 메인에는 스냅샷만 전달한다.
final class ScanCoverageTracker {
    static let processInterval: TimeInterval = 0.20
    /// depth 맵 다운샘플 스텝 (픽셀).
    private static let sampleStride = 8

    private let coverage = ScanCoverage()
    private let surfaceFusion = TemporalSurfaceFusion(cellSize: 0.02)
    private let queue = DispatchQueue(label: "trueputt.scan-coverage", qos: .userInitiated)
    private var lastProcessTime: TimeInterval = 0
    private var processing = false
    private(set) var latestSnapshot = ScanCoverageSnapshot.empty
    private var tiltStabilizer = CameraTiltStabilizer(configuration: .scanDepth)
    private var scanPhase: ScanDepthPhase = .walkCorridor
    private var behindBallStartTime: TimeInterval = 0
    private var behindBallProcessedFrames = 0
    private var behindBallAcceptedSamples = 0
    private var behindBallAcceptedCellKeys: Set<Int64> = []
    private var behindBallGoodFrames = 0
    private(set) var latestBehindBallStats = BehindBallSweepGate.Stats.empty
    private var walkStartTime: TimeInterval = 0
    private var walkProcessedFrames = 0
    private var walkRibbonSamples = 0
    private var walkRibbonCellKeys: Set<Int64> = []
    private var walkGoodFrames = 0
    private var walkMaxDistanceFromBall = 0.0
    private var walkInBandFrameCount = 0
    private(set) var latestWalkCorridorStats = WalkCorridorGate.Stats.empty

    func reset() {
        queue.async {
            self.coverage.reset()
            self.surfaceFusion.reset()
            self.lastProcessTime = 0
            self.processing = false
            self.latestSnapshot = .empty
            self.resetBehindBallAccumulatorLocked()
            self.resetWalkCorridorAccumulatorLocked()
        }
    }

    func setPhase(_ phase: ScanDepthPhase) {
        queue.async {
            self.scanPhase = phase
            if phase == .behindBallSweep {
                self.resetBehindBallAccumulatorLocked()
            } else if phase == .walkCorridor {
                self.resetWalkCorridorAccumulatorLocked()
            }
        }
    }

    func resetBehindBallAccumulator() {
        queue.async {
            self.resetBehindBallAccumulatorLocked()
        }
    }

    func resetWalkCorridorAccumulator() {
        queue.async {
            self.resetWalkCorridorAccumulatorLocked()
        }
    }

    private func resetBehindBallAccumulatorLocked() {
        behindBallStartTime = 0
        behindBallProcessedFrames = 0
        behindBallAcceptedSamples = 0
        behindBallAcceptedCellKeys.removeAll(keepingCapacity: true)
        behindBallGoodFrames = 0
        latestBehindBallStats = .empty
    }

    private func resetWalkCorridorAccumulatorLocked() {
        walkStartTime = 0
        walkProcessedFrames = 0
        walkRibbonSamples = 0
        walkRibbonCellKeys.removeAll(keepingCapacity: true)
        walkGoodFrames = 0
        walkMaxDistanceFromBall = 0
        walkInBandFrameCount = 0
        latestWalkCorridorStats = .empty
    }

    func behindBallSweepStats(now: TimeInterval) async -> BehindBallSweepGate.Stats {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.behindBallStatsSnapshot(now: now))
            }
        }
    }

    /// 메인스레드를 막지 않는 리셋 (스캔 시작 버튼용).
    func resetAsync() {
        tiltStabilizer.reset()
        reset()
    }

    /// 볼 확정 등 — 이후 depth 역투영 pitch/roll 기준.
    func captureTiltReference(from cameraTransform: simd_float4x4) {
        tiltStabilizer.captureReference(from: cameraTransform)
    }

    /// 프레임당 최대 한 번. 결과는 completion으로 메인 호출 권장.
    /// `ballY`가 있으면 볼보다 과도하게 높은 점(발)을 융합에서 제외한다.
    /// `ballXZ`가 있으면 편도 걸을 때 볼→카메라 구간 셀을 우선 보존한다.
    func process(
        frame: ARFrame,
        trackingLimited: Bool,
        phase: ScanDepthPhase = .walkCorridor,
        ball: ScanPose? = nil,
        ballY: Double? = nil,
        ballXZ: SIMD2<Double>? = nil,
        completion: @escaping (ScanCoverageSnapshot) -> Void
    ) {
        let now = frame.timestamp
        guard now - lastProcessTime >= Self.processInterval else { return }
        guard !processing else { return }
        // 물리 융합 정밀도를 위해 모션 지연이 없는 raw sceneDepth만 사용한다.
        // (smoothedSceneDepth는 세션 구성에서 요청하지 않음 — 부하 절감)
        guard let depthData = frame.sceneDepth else { return }

        lastProcessTime = now
        processing = true

        // depth 픽셀 복사는 백그라운드에서 — 메인에서 하면 스캔 시작 직후 수 초~수십 초 멈춘 것처럼.
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        let rawCameraTransform = frame.camera.transform
        let cameraTransform = tiltStabilizer.stabilizedTransform(from: rawCameraTransform)
        let intrinsics = frame.camera.intrinsics
        let imageResolution = frame.camera.imageResolution
        let cameraPosition = SIMD3<Float>(
            rawCameraTransform.columns.3.x,
            rawCameraTransform.columns.3.y,
            rawCameraTransform.columns.3.z
        )

        queue.async { [weak self] in
            defer {
                self?.processing = false
            }
            guard let self else { return }
            let samples = Self.copyDepthSamples(
                depthMap: depthMap,
                confidenceMap: confidenceMap,
                cameraIntrinsics: intrinsics,
                imageResolution: imageResolution,
                cameraToWorld: cameraTransform,
                sampleStep: Self.sampleStride
            )
            let snapshot = self.coverage.ingest(
                points: samples,
                cameraPosition: cameraPosition,
                timestamp: now,
                trackingLimited: trackingLimited
            )
            // 실제 높이 융합에는 high confidence만 사용. 발·다리 국소 돌출은 제거.
            let rawFusion: [GroundScanFilter.Point] = samples.compactMap { point in
                guard point.confidence >= 2 else { return nil }
                return GroundScanFilter.Point(
                    worldX: Double(point.worldX),
                    worldY: Double(point.worldY),
                    worldZ: Double(point.worldZ)
                )
            }
            let cleaned = GroundScanFilter.cleanTerrainPoints(
                rawFusion,
                cameraX: Double(cameraPosition.x),
                cameraY: Double(cameraPosition.y),
                cameraZ: Double(cameraPosition.z),
                ballY: ballY
            )
            let cameraXZ = SIMD2<Double>(Double(cameraPosition.x), Double(cameraPosition.z))
            let fusionSamples: [TemporalSurfaceFusion.Sample]
            if phase == .behindBallSweep, let ball {
                let lookX = Double(-rawCameraTransform.columns.2.x)
                let lookZ = Double(-rawCameraTransform.columns.2.z)
                if let forward = BehindBallSweepGate.forwardDirection(lookX: lookX, lookZ: lookZ) {
                    let context = BehindBallSweepGate.Context(
                        ballX: ball.worldX,
                        ballY: ball.worldY,
                        ballZ: ball.worldZ,
                        cameraX: Double(cameraPosition.x),
                        cameraY: Double(cameraPosition.y),
                        cameraZ: Double(cameraPosition.z),
                        forwardX: forward.x,
                        forwardZ: forward.z
                    )
                    var acceptedInFrame = 0
                    if self.behindBallStartTime == 0 {
                        self.behindBallStartTime = now
                    }
                    self.behindBallProcessedFrames += 1
                    var gated: [GroundScanFilter.Point] = []
                    gated.reserveCapacity(cleaned.count)
                    for point in cleaned {
                        let sample = BehindBallSweepGate.Sample(
                            worldX: point.worldX,
                            worldY: point.worldY,
                            worldZ: point.worldZ,
                            confidence: 2
                        )
                        guard BehindBallSweepGate.accepts(sample: sample, context: context) else { continue }
                        gated.append(point)
                        acceptedInFrame += 1
                        self.behindBallAcceptedSamples += 1
                        let key = BehindBallSweepGate.cellKey(x: point.worldX, z: point.worldZ)
                        self.behindBallAcceptedCellKeys.insert(key)
                    }
                    if acceptedInFrame >= BehindBallSweepGate.goodFrameSampleThreshold {
                        self.behindBallGoodFrames += 1
                    }
                    fusionSamples = gated.map {
                        TemporalSurfaceFusion.Sample(
                            worldX: $0.worldX,
                            worldY: $0.worldY,
                            worldZ: $0.worldZ,
                            timestamp: now
                        )
                    }
                } else {
                    fusionSamples = []
                }
                self.latestBehindBallStats = self.behindBallStatsSnapshot(now: now)
            } else {
                fusionSamples = cleaned.map {
                    TemporalSurfaceFusion.Sample(
                        worldX: $0.worldX,
                        worldY: $0.worldY,
                        worldZ: $0.worldZ,
                        timestamp: now
                    )
                }
                if phase == .walkCorridor, let ball {
                    self.accumulateWalkCorridor(
                        cleaned: cleaned,
                        ball: ball,
                        cameraPosition: cameraPosition,
                        rawCameraTransform: rawCameraTransform,
                        now: now
                    )
                }
            }
            // prune 끝점은 카메라(볼→현재 위치). 옆으로 밀면 등고가 라인 한쪽으로 치우침.
            let pathEndXZ = cameraXZ
            if !fusionSamples.isEmpty {
                self.surfaceFusion.ingestFrame(
                    fusionSamples,
                    timestamp: now,
                    cameraXZ: cameraXZ,
                    keepNearBallXZ: ballXZ,
                    keepNearPathEndXZ: phase == .behindBallSweep ? ballXZ : pathEndXZ
                )
            }
            self.scanPhase = phase
            self.latestSnapshot = snapshot
            DispatchQueue.main.async {
                completion(snapshot)
            }
        }
    }

    /// 완료 시점의 다중 프레임 융합 지면. 호출 스레드를 막지 않는다.
    func fusedGroundVerticesAsync(
        ball: ScanPose,
        hole: ScanPose,
        margins: ScanCorridorMargins = PuttScanCorridor.tuningMargins
    ) async -> [ScanVertex] {
        await withCheckedContinuation { continuation in
            queue.async {
                let vertices = self.surfaceFusion.fusedVertices(
                    referenceHeight: ball.worldY,
                    ballX: ball.worldX,
                    ballZ: ball.worldZ,
                    holeX: hole.worldX,
                    holeZ: hole.worldZ,
                    lateralMargin: margins.lateralHalfWidth,
                    ballEndMargin: margins.ballEndMargin,
                    pastHoleMargin: margins.pastHoleMargin,
                    heightTolerance: 0.22
                )
                // 융합 후에도 잔여 발 스파이크를 한 번 더 제거
                let points = vertices.map {
                    GroundScanFilter.Point(worldX: $0.worldX, worldY: $0.worldY, worldZ: $0.worldZ)
                }
                let cleaned = GroundScanFilter.cleanTerrainPoints(points, ballY: ball.worldY)
                let result: [ScanVertex] = cleaned.map { point in
                    ScanVertex(
                        worldX: point.worldX,
                        worldY: point.worldY,
                        worldZ: point.worldZ,
                        timestamp: 0
                    )
                }
                continuation.resume(returning: result)
            }
        }
    }

    private static func copyDepthSamples(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        cameraIntrinsics: simd_float3x3,
        imageResolution: CGSize,
        cameraToWorld: simd_float4x4,
        sampleStep: Int
    ) -> [ScanCoveragePoint] {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return [] }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        var confidenceLocked = false
        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceBytesPerRow = 0
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceLocked = true
            confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap)
            confidenceBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if confidenceLocked, let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        // depth 해상도에 맞게 intrinsics 스케일
        let scaleX = Float(width) / Float(max(imageResolution.width, 1))
        let scaleY = Float(height) / Float(max(imageResolution.height, 1))
        var depthIntrinsics = cameraIntrinsics
        depthIntrinsics[0, 0] *= scaleX
        depthIntrinsics[1, 1] *= scaleY
        depthIntrinsics[2, 0] *= scaleX
        depthIntrinsics[2, 1] *= scaleY

        let step = max(sampleStep, 1)
        var points: [ScanCoveragePoint] = []
        points.reserveCapacity((width / step + 1) * (height / step + 1))

        for y in Swift.stride(from: 0, to: height, by: step) {
            let depthRow = UnsafeRawPointer(depthBase)
                .advanced(by: depthBytesPerRow * y)
                .assumingMemoryBound(to: Float32.self)
            let confRow: UnsafePointer<UInt8>? = {
                guard let confidenceBase else { return nil }
                return UnsafeRawPointer(confidenceBase)
                    .advanced(by: confidenceBytesPerRow * y)
                    .assumingMemoryBound(to: UInt8.self)
            }()

            for x in Swift.stride(from: 0, to: width, by: step) {
                let depth = depthRow[x]
                guard depth.isFinite else { continue }

                let confidence = confRow?[x] ?? 2
                guard confidence >= ScanCoverage.minConfidence else { continue }

                guard let world = ScanCoverage.unproject(
                    depthX: Float(x),
                    depthY: Float(y),
                    depthMeters: depth,
                    intrinsics: depthIntrinsics,
                    cameraToWorld: cameraToWorld
                ) else { continue }

                points.append(
                    ScanCoveragePoint(
                        worldX: world.x,
                        worldY: world.y,
                        worldZ: world.z,
                        confidence: confidence
                    )
                )
            }
        }

        return points
    }

    private func behindBallStatsSnapshot(now: TimeInterval) -> BehindBallSweepGate.Stats {
        let duration = behindBallStartTime > 0 ? max(0, now - behindBallStartTime) : 0
        let stats = BehindBallSweepGate.Stats(
            durationSeconds: duration,
            processedFrames: behindBallProcessedFrames,
            acceptedSamples: behindBallAcceptedSamples,
            acceptedCells: behindBallAcceptedCellKeys.count,
            goodFrames: behindBallGoodFrames,
            qualityMet: false
        )
        return BehindBallSweepGate.Stats(
            durationSeconds: stats.durationSeconds,
            processedFrames: stats.processedFrames,
            acceptedSamples: stats.acceptedSamples,
            acceptedCells: stats.acceptedCells,
            goodFrames: stats.goodFrames,
            qualityMet: BehindBallSweepGate.qualityMet(stats: stats)
        )
    }

    private func accumulateWalkCorridor(
        cleaned: [GroundScanFilter.Point],
        ball: ScanPose,
        cameraPosition: SIMD3<Float>,
        rawCameraTransform: simd_float4x4,
        now: TimeInterval
    ) {
        let lookX = Double(-rawCameraTransform.columns.2.x)
        let lookZ = Double(-rawCameraTransform.columns.2.z)
        guard let forward = BehindBallSweepGate.forwardDirection(lookX: lookX, lookZ: lookZ) else { return }
        let context = WalkCorridorGate.Context(
            ballX: ball.worldX,
            ballY: ball.worldY,
            ballZ: ball.worldZ,
            cameraX: Double(cameraPosition.x),
            cameraY: Double(cameraPosition.y),
            cameraZ: Double(cameraPosition.z),
            forwardX: forward.x,
            forwardZ: forward.z
        )
        if walkStartTime == 0 {
            walkStartTime = now
        }
        walkProcessedFrames += 1
        walkMaxDistanceFromBall = max(walkMaxDistanceFromBall, context.distanceFromBallXZ)

        var ribbonInFrame = 0
        for point in cleaned {
            let sample = WalkCorridorGate.Sample(
                worldX: point.worldX,
                worldY: point.worldY,
                worldZ: point.worldZ,
                confidence: 2
            )
            guard WalkCorridorGate.countsTowardRibbon(sample: sample, context: context) else { continue }
            ribbonInFrame += 1
            walkRibbonSamples += 1
            walkRibbonCellKeys.insert(WalkCorridorGate.cellKey(x: point.worldX, z: point.worldZ))
        }
        if ribbonInFrame >= WalkCorridorGate.goodFrameSampleThreshold {
            walkGoodFrames += 1
        }
        latestWalkCorridorStats = walkCorridorStatsSnapshot(now: now)
    }

    private func walkCorridorStatsSnapshot(now: TimeInterval) -> WalkCorridorGate.Stats {
        let duration = walkStartTime > 0 ? max(0, now - walkStartTime) : 0
        let stats = WalkCorridorGate.Stats(
            durationSeconds: duration,
            processedFrames: walkProcessedFrames,
            ribbonSamples: walkRibbonSamples,
            ribbonCells: walkRibbonCellKeys.count,
            goodFrames: walkGoodFrames,
            maxDistanceFromBall: walkMaxDistanceFromBall,
            inBandFrameCount: walkInBandFrameCount,
            qualityMet: false
        )
        return WalkCorridorGate.Stats(
            durationSeconds: stats.durationSeconds,
            processedFrames: stats.processedFrames,
            ribbonSamples: stats.ribbonSamples,
            ribbonCells: stats.ribbonCells,
            goodFrames: stats.goodFrames,
            maxDistanceFromBall: stats.maxDistanceFromBall,
            inBandFrameCount: stats.inBandFrameCount,
            qualityMet: WalkCorridorGate.qualityMet(stats: stats)
        )
    }

    func applyWalkTwistInBand(_ inBand: Bool, frameTimestamp: TimeInterval) {
        queue.async {
            guard self.scanPhase == .walkCorridor else { return }
            if inBand {
                self.walkInBandFrameCount += 1
            }
            self.latestWalkCorridorStats = self.walkCorridorStatsSnapshot(now: frameTimestamp)
        }
    }
}
