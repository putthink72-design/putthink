import ARKit
import Foundation
import PuttPhysicsKit
import simd

/// ARKit sceneDepth → ScanCoverage 순수 코어 브리지.
/// 배경 큐에서 샘플링하고, 메인에는 스냅샷만 전달한다.
final class ScanCoverageTracker {
    static let processInterval: TimeInterval = 0.33
    /// depth 맵 다운샘플 스텝 (픽셀).
    private static let sampleStride = 8

    private let coverage = ScanCoverage()
    private let surfaceFusion = TemporalSurfaceFusion(cellSize: 0.01)
    private let queue = DispatchQueue(label: "trueputt.scan-coverage", qos: .utility)
    private var lastProcessTime: TimeInterval = 0
    private var processing = false
    private(set) var latestSnapshot = ScanCoverageSnapshot.empty
    private var tiltStabilizer = CameraTiltStabilizer(configuration: .scanDepth)

    func reset() {
        queue.async {
            self.coverage.reset()
            self.surfaceFusion.reset()
            self.lastProcessTime = 0
            self.processing = false
            self.latestSnapshot = .empty
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
    func process(
        frame: ARFrame,
        trackingLimited: Bool,
        ballY: Double? = nil,
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

        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        let rawCameraTransform = frame.camera.transform
        // 걸음 pitch/roll 떨림이 depth 역투영 Y에 직접 들어가므로 yaw·위치만 유지하고 기울기 보정.
        let cameraTransform = tiltStabilizer.stabilizedTransform(from: rawCameraTransform)
        let intrinsics = frame.camera.intrinsics
        let imageResolution = frame.camera.imageResolution

        let samples = Self.copyDepthSamples(
            depthMap: depthMap,
            confidenceMap: confidenceMap,
            cameraIntrinsics: intrinsics,
            imageResolution: imageResolution,
            cameraToWorld: cameraTransform,
            sampleStep: Self.sampleStride
        )
        let cameraPosition = SIMD3<Float>(
            rawCameraTransform.columns.3.x,
            rawCameraTransform.columns.3.y,
            rawCameraTransform.columns.3.z
        )

        queue.async { [weak self] in
            guard let self else { return }
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
            let fusionSamples = cleaned.map {
                TemporalSurfaceFusion.Sample(
                    worldX: $0.worldX,
                    worldY: $0.worldY,
                    worldZ: $0.worldZ,
                    timestamp: now
                )
            }
            let cameraXZ = SIMD2<Double>(Double(cameraPosition.x), Double(cameraPosition.z))
            self.surfaceFusion.ingestFrame(fusionSamples, timestamp: now, cameraXZ: cameraXZ)
            self.latestSnapshot = snapshot
            self.processing = false
            DispatchQueue.main.async {
                completion(snapshot)
            }
        }
    }

    /// 완료 시점의 다중 프레임 융합 지면. 호출 스레드를 막지 않는다.
    func fusedGroundVerticesAsync(ball: ScanPose, hole: ScanPose) async -> [ScanVertex] {
        await withCheckedContinuation { continuation in
            queue.async {
                let vertices = self.surfaceFusion.fusedVertices(
                    referenceHeight: ball.worldY,
                    ballX: ball.worldX,
                    ballZ: ball.worldZ,
                    holeX: hole.worldX,
                    holeZ: hole.worldZ,
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
}
