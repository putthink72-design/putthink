import ARKit
import CoreVideo
import Foundation
import PuttPhysicsKit
import simd
import UIKit

/// 화면 표시용 후보 (카메라 이미지 좌표 → 세로 AR 뷰 정규화).
struct Gate6DisplayCandidate: Equatable {
    var viewNormalizedX: Double
    var viewNormalizedY: Double
    var radiusNorm: Double
    var score: Double
    var depthAccepted: Bool
}

/// 한 프레임의 섀도 관측. 앵커에 절대 쓰지 않는다.
struct Gate6ShadowObservation: Equatable {
    var kind: Gate6TargetKind
    var rgbCandidateCount: Int
    var depthRejectedCount: Int
    var best: Gate6DetectionResult?
    var allScreenCandidates: [Gate6ImageCandidate]
    var displayCandidates: [Gate6DisplayCandidate]
    var timestamp: TimeInterval
    var depthAvailable: Bool

    var statusLine: String {
        if !depthAvailable {
            return "자동인식(섀도) \(kind == .ball ? "볼" : "홀") · RGB \(rgbCandidateCount) · 깊이 대기"
        }
        let depthOK = best?.depth.accepted == true
        if let best, depthOK {
            return String(
                format: "자동인식(섀도) %@ · RGB %d · 깊이통과 · 점수 %.0f%%",
                kind == .ball ? "볼" : "홀",
                rgbCandidateCount,
                best.candidate.score * 100
            )
        }
        if rgbCandidateCount == 0 {
            return "자동인식(섀도) \(kind == .ball ? "볼" : "홀") · RGB 후보 없음 (더 가까이·밝게)"
        }
        return String(
            format: "자동인식(섀도) %@ · RGB %d · 깊이기각 %d (노란 원=RGB만)",
            kind == .ball ? "볼" : "홀",
            rgbCandidateCount,
            depthRejectedCount
        )
    }
}

enum Gate6RGBDepthDetector {
    /// ARFrame에서 RGB 후보 + 깊이 교차검증. 월드좌표까지 채운 관측을 반환.
    static func observe(
        frame: ARFrame,
        kind: Gate6TargetKind,
        viewportSize: CGSize = CGSize(width: 390, height: 844)
    ) -> Gate6ShadowObservation? {
        // 흰 공은 해상도가 중요 — 짧은 변 기준 240px
        guard let luma = downsampleLuma(from: frame.capturedImage, maxSide: 240) else { return nil }

        let rgbCandidates: [Gate6ImageCandidate]
        switch kind {
        case .ball:
            rgbCandidates = Gate6Detection.extractBrightBallCandidates(
                luma: luma.bytes,
                width: luma.width,
                height: luma.height,
                minAbsoluteLuma: 145,
                minScore: 0.14
            )
        case .hole:
            rgbCandidates = Gate6Detection.extractSyntheticRGBCandidates(
                kind: .hole,
                luma: luma.bytes,
                width: luma.width,
                height: luma.height,
                minScore: 0.25
            )
        }

        // 세션 구성에서 smoothedSceneDepth를 요청하지 않으므로 raw만 사용.
        let depthData = frame.sceneDepth
        let gateDepth = depthData.flatMap { copyDepthMap($0.depthMap) }
        let depthAvailable = gateDepth != nil

        var bestCore: Gate6DetectionResult?
        var rejected = 0
        var rgbCount = rgbCandidates.count
        if let gateDepth {
            let selected = Gate6Detection.selectBest(
                kind: kind,
                candidates: rgbCandidates,
                depth: gateDepth
            )
            bestCore = selected.best
            rejected = selected.rejectedByDepth
            rgbCount = selected.rgbCount
        }

        var best = bestCore
        if var accepted = best, accepted.depth.accepted, let gateDepth {
            if let world = unproject(
                normalizedX: accepted.candidate.normalizedX,
                normalizedY: accepted.candidate.normalizedY,
                depthMeters: accepted.depth.centerDepthMeters ?? Double(gateDepth.sample(
                    normalizedX: accepted.candidate.normalizedX,
                    normalizedY: accepted.candidate.normalizedY
                ) ?? 0),
                frame: frame
            ) {
                accepted.worldX = Double(world.x)
                accepted.worldY = Double(world.y)
                accepted.worldZ = Double(world.z)
                best = accepted
            }
        }

        // 표시는 상위 점수 6개 + 통과 후보 우선.
        var displaySource = Array(rgbCandidates.sorted { $0.score > $1.score }.prefix(6))
        if let best, !displaySource.contains(best.candidate) {
            displaySource.append(best.candidate)
        }
        let display = makeDisplayCandidates(
            imageCandidates: displaySource,
            best: best,
            frame: frame,
            viewportSize: viewportSize
        )

        return Gate6ShadowObservation(
            kind: kind,
            rgbCandidateCount: rgbCount,
            depthRejectedCount: rejected,
            best: best,
            allScreenCandidates: displaySource,
            displayCandidates: display,
            timestamp: frame.timestamp,
            depthAvailable: depthAvailable
        )
    }

    /// 시뮬레이터/테스트용 합성 관측.
    static func observeSynthetic(kind: Gate6TargetKind) -> Gate6ShadowObservation {
        let depth: Gate6DepthMap
        switch kind {
        case .ball:
            depth = Gate6DepthMap(
                width: 32,
                height: 32,
                meters: (0..<1024).map { i in
                    let x = i % 32
                    let y = i / 32
                    let d = hypot(Double(x) - 16, Double(y) - 16)
                    return d < 3 ? 1.48 : 1.50
                }
            )
        case .hole:
            depth = Gate6DepthMap(
                width: 32,
                height: 32,
                meters: (0..<1024).map { i in
                    let x = i % 32
                    let y = i / 32
                    let d = hypot(Double(x) - 16, Double(y) - 16)
                    return d < 4 ? 1.53 : 1.50
                }
            )
        }
        var luma = [UInt8](repeating: 100, count: 32 * 32)
        for y in 14...18 {
            for x in 14...18 {
                luma[y * 32 + x] = kind == .ball ? 230 : 40
            }
        }
        let rgb: [Gate6ImageCandidate]
        switch kind {
        case .ball:
            rgb = Gate6Detection.extractBrightBallCandidates(
                luma: luma, width: 32, height: 32, minAbsoluteLuma: 150
            )
        case .hole:
            rgb = Gate6Detection.extractSyntheticRGBCandidates(
                kind: .hole, luma: luma, width: 32, height: 32
            )
        }
        let (best, rejected, count) = Gate6Detection.selectBest(
            kind: kind, candidates: rgb, depth: depth
        )
        var filled = best
        if var b = filled {
            b.worldX = 0
            b.worldY = kind == .ball ? 0.3 : 0.33
            b.worldZ = kind == .ball ? 0 : 3
            filled = b
        }
        let display = rgb.prefix(8).map {
            Gate6DisplayCandidate(
                viewNormalizedX: $0.normalizedX,
                viewNormalizedY: $0.normalizedY,
                radiusNorm: $0.radiusNorm,
                score: $0.score,
                depthAccepted: filled?.candidate == $0 && filled?.depth.accepted == true
            )
        }
        return Gate6ShadowObservation(
            kind: kind,
            rgbCandidateCount: count,
            depthRejectedCount: rejected,
            best: filled,
            allScreenCandidates: rgb,
            displayCandidates: Array(display),
            timestamp: 0,
            depthAvailable: true
        )
    }

    // MARK: - Display mapping

    private static func makeDisplayCandidates(
        imageCandidates: [Gate6ImageCandidate],
        best: Gate6DetectionResult?,
        frame: ARFrame,
        viewportSize: CGSize
    ) -> [Gate6DisplayCandidate] {
        // 실제 세로 뷰 크기로 displayTransform을 계산해야 종횡비 왜곡이 없음.
        // 출력은 뷰 정규화(0…1) 좌표.
        let transform = frame.displayTransform(
            for: .portrait,
            viewportSize: viewportSize
        )
        return imageCandidates.compactMap { candidate in
            let point = CGPoint(x: candidate.normalizedX, y: candidate.normalizedY)
                .applying(transform)
            let vx = Double(point.x)
            let vy = Double(point.y)
            guard vx > -0.05, vx < 1.05, vy > -0.05, vy < 1.05 else { return nil }
            let accepted = best?.candidate == candidate && best?.depth.accepted == true
            return Gate6DisplayCandidate(
                viewNormalizedX: min(1, max(0, vx)),
                viewNormalizedY: min(1, max(0, vy)),
                radiusNorm: max(candidate.radiusNorm, 0.02),
                score: candidate.score,
                depthAccepted: accepted
            )
        }
    }

    // MARK: - Depth / RGB helpers

    private static func copyDepthMap(_ buffer: CVPixelBuffer) -> Gate6DepthMap? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let src = base.assumingMemoryBound(to: Float32.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.size
        // 다운샘플 (골프공 몇 픽셀 보존을 위해 더 촘촘히)
        let strideX = max(1, width / 120)
        let strideY = max(1, height / 90)
        let outW = max(1, width / strideX)
        let outH = max(1, height / strideY)
        var meters = [Float](repeating: 0, count: outW * outH)
        for oy in 0..<outH {
            for ox in 0..<outW {
                let sx = min(ox * strideX, width - 1)
                let sy = min(oy * strideY, height - 1)
                meters[oy * outW + ox] = src[sy * bytesPerRow + sx]
            }
        }
        return Gate6DepthMap(width: outW, height: outH, meters: meters)
    }

    private struct LumaImage {
        var width: Int
        var height: Int
        var bytes: [UInt8]
    }

    private static func downsampleLuma(from buffer: CVPixelBuffer, maxSide: Int) -> LumaImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else {
            return nil
        }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)

        let scale = max(1, max(width, height) / maxSide)
        let outW = max(1, width / scale)
        let outH = max(1, height / scale)
        var bytes = [UInt8](repeating: 0, count: outW * outH)
        for oy in 0..<outH {
            for ox in 0..<outW {
                let sx = min(ox * scale, width - 1)
                let sy = min(oy * scale, height - 1)
                bytes[oy * outW + ox] = yPtr[sy * yBytesPerRow + sx]
            }
        }
        return LumaImage(width: outW, height: outH, bytes: bytes)
    }

    private static func unproject(
        normalizedX: Double,
        normalizedY: Double,
        depthMeters: Double,
        frame: ARFrame
    ) -> SIMD3<Float>? {
        guard depthMeters > 0.05, depthMeters < 20 else { return nil }
        let intrinsics = frame.camera.intrinsics
        let imageResolution = frame.camera.imageResolution
        let px = Float(normalizedX) * Float(imageResolution.width)
        let py = Float(normalizedY) * Float(imageResolution.height)
        let fx = intrinsics[0, 0]
        let fy = intrinsics[1, 1]
        let cx = intrinsics[2, 0]
        let cy = intrinsics[2, 1]
        let x = (px - cx) * Float(depthMeters) / fx
        let y = (py - cy) * Float(depthMeters) / fy
        let z = -Float(depthMeters)
        let cameraLocal = SIMD4<Float>(x, y, z, 1)
        let world = frame.camera.transform * cameraLocal
        return SIMD3(world.x, world.y, world.z)
    }
}
