import ARKit
import CoreVideo
import Foundation
import PuttPhysicsKit
import simd
import UIKit

/// ARFrame → RGB 다운샘플 + 공 주변 LiDAR 지면 고리. 감지 본체는 PuttPhysicsKit.
enum GolfBallVisualLockSession {
    static let detectionWidth = 960
    /// 배치 단계: 30Hz 근처. 경쟁 앱은 십자선 고정 시 거의 즉시 반응한다.
    static let placingProcessInterval: TimeInterval = 1.0 / 30.0
    static let guidanceProcessInterval: TimeInterval = 0.07
    static var processInterval: TimeInterval { placingProcessInterval }
    /// 십자선 주변 네이티브 크롭(px). 작을수록 빠르고 십자선 정렬 UX와 맞다.
    static let placingPatchPixels = 280
    /// 십자선 주변 탐색 창(m). 스캔 시작·십자선 정렬용.
    static let reticleWindowMeters = 0.55
    /// 월드 볼 앵커 투영 주변 탐색 창(m). 조준 복귀·하안 근접용.
    static let worldBallWindowMeters = 0.32

    struct CopiedDepth {
        var width: Int
        var height: Int
        /// 전체 depth 맵에서 이 패치의 좌상단.
        var originX: Int
        var originY: Int
        var mapWidth: Int
        var mapHeight: Int
        var depths: [Float]
        var confidence: [UInt8]
        var intrinsics: simd_float3x3
        var cameraToWorld: simd_float4x4
    }

    struct Snapshot {
        var image: GolfBallImageBuffer
        var sourceWidth: Int
        var sourceHeight: Int
        var sourceOriginX: Double
        var sourceOriginY: Double
        var detectionToSource: Double
        var rgbIntrinsics: simd_float3x3
        var cameraToWorld: simd_float4x4
        var hint: GolfBallDetectionHint
        var depth: CopiedDepth?
        var currentBall: ScanPose?

        func sourcePixel(x: Double, y: Double) -> (x: Double, y: Double) {
            (
                sourceOriginX + x * detectionToSource,
                sourceOriginY + y * detectionToSource
            )
        }
    }

    /// delegate 스레드에서 버퍼를 복사한다. 픽셀 버퍼를 넘기지 말 것.
    static func snapshot(
        frame: ARFrame,
        currentBall: ScanPose?,
        viewport: CGSize,
        orientation: UIInterfaceOrientation
    ) -> Snapshot? {
        let camera = frame.camera
        let sourceSize = camera.imageResolution
        let sourceWidth = Int(sourceSize.width)
        let sourceHeight = Int(sourceSize.height)
        guard sourceWidth > 32, sourceHeight > 32 else { return nil }
        let bufferWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let bufferHeight = CVPixelBufferGetHeight(frame.capturedImage)
        guard bufferWidth > 32, bufferHeight > 32 else { return nil }
        let bufferScaleX = Double(bufferWidth) / Double(sourceWidth)
        let bufferScaleY = Double(bufferHeight) / Double(sourceHeight)

        let target = aimPointInCapturedImage(
            frame: frame,
            currentBall: currentBall,
            viewport: viewport,
            orientation: orientation,
            bufferWidth: bufferWidth,
            bufferHeight: bufferHeight
        )
        let fxBuffer = Double(camera.intrinsics[0, 0]) * bufferScaleX
        let depthMeters = sampleDepthMeters(
            frame: frame,
            sourceX: target.x / bufferScaleX,
            sourceY: target.y / bufferScaleY
        )
        let distance: Double
        if let ball = currentBall {
            let cam = camera.transform.columns.3
            let dx = Double(cam.x) - ball.worldX
            let dy = Double(cam.y) - ball.worldY
            let dz = Double(cam.z) - ball.worldZ
            distance = min(max(sqrt(dx * dx + dy * dy + dz * dz), 0.35), 8.0)
        } else {
            distance = min(max(depthMeters ?? 1.3, 0.50), 1.70)
        }
        let expectedDisk = GolfBallWorldLocalizer.expectedRadiusPixels(
            focalX: fxBuffer,
            distanceMeters: distance
        )
        let farDisk = GolfBallWorldLocalizer.expectedRadiusPixels(
            focalX: fxBuffer,
            distanceMeters: 1.55
        )
        let patch = placingPatchSize(
            focalX: fxBuffer,
            distanceMeters: distance,
            worldAnchored: currentBall != nil
        )

        let makeHint = { (centerX: Double, centerY: Double, width: Int, height: Int, disk: Double, far: Double) in
            if currentBall != nil {
                return GolfBallDetectionHint.aroundWorldAnchor(
                    centerX: centerX,
                    centerY: centerY,
                    width: width,
                    height: height,
                    expectedRadiusPixels: disk,
                    distanceMeters: distance,
                    farRadiusPixels: far
                )
            }
            return GolfBallDetectionHint.aroundReticle(
                centerX: centerX,
                centerY: centerY,
                width: width,
                height: height,
                expectedRadiusPixels: disk,
                farRadiusPixels: far
            )
        }

        if let patchImage = extractPatch(
            frame.capturedImage,
            centerX: target.x,
            centerY: target.y,
            patchSize: patch
        ) {
            let hint = makeHint(
                target.x - Double(patchImage.originX),
                target.y - Double(patchImage.originY),
                patchImage.image.width,
                patchImage.image.height,
                expectedDisk,
                farDisk
            )
            return Snapshot(
                image: patchImage.image,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                sourceOriginX: Double(patchImage.originX) / bufferScaleX,
                sourceOriginY: Double(patchImage.originY) / bufferScaleY,
                detectionToSource: 1 / bufferScaleX,
                rgbIntrinsics: camera.intrinsics,
                cameraToWorld: camera.transform,
                hint: hint,
                depth: copyDepthPatch(
                    frame,
                    sourceX: target.x / bufferScaleX,
                    sourceY: target.y / bufferScaleY,
                    radiusSourcePixels: max(24, expectedDisk * 2.8)
                ),
                currentBall: currentBall
            )
        }

        guard let image = downsampleCapturedImage(frame.capturedImage, targetWidth: detectionWidth) else {
            return nil
        }
        let toDetectX = Double(image.width) / Double(bufferWidth)
        let toDetectY = Double(image.height) / Double(bufferHeight)
        let hint = makeHint(
            target.x * toDetectX,
            target.y * toDetectY,
            image.width,
            image.height,
            expectedDisk * toDetectX,
            farDisk * toDetectX
        )
        return Snapshot(
            image: image,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceOriginX: 0,
            sourceOriginY: 0,
            detectionToSource: Double(sourceWidth) / Double(max(image.width, 1)),
            rgbIntrinsics: camera.intrinsics,
            cameraToWorld: camera.transform,
            hint: hint,
            depth: copyDepthPatch(
                frame,
                sourceX: target.x / bufferScaleX,
                sourceY: target.y / bufferScaleY,
                radiusSourcePixels: max(24, expectedDisk * 2.8)
            ),
            currentBall: currentBall
        )
    }

    private static func placingPatchSize(
        focalX: Double,
        distanceMeters: Double,
        worldAnchored: Bool
    ) -> Int {
        let window = worldAnchored ? worldBallWindowMeters : reticleWindowMeters
        let fromGeometry = Int((focalX * window / distanceMeters).rounded())
        let cap = worldAnchored ? min(placingPatchPixels, 240) : placingPatchPixels
        let size = min(cap, max(worldAnchored ? 168 : 200, fromGeometry))
        return size & ~1
    }

    static func analyze(_ snapshot: Snapshot) -> GolfBallWorldContact? {
        guard let blob = GolfBallRGBDetector.detect(image: snapshot.image, hint: snapshot.hint) else {
            return nil
        }
        let ring = depthRing(
            around: blob,
            snapshot: snapshot
        )
        if let medianDepth = ring.medianDepth,
           let diameter = GolfBallWorldLocalizer.apparentDiameterMeters(
            radiusSourcePixels: blob.radiusPixels * snapshot.detectionToSource,
            depthMeters: Double(medianDepth),
            focalX: Double(snapshot.rgbIntrinsics[0, 0])
           ),
           diameter > 0.18 {
            return nil
        }

        let source = snapshot.sourcePixel(x: blob.centerX, y: blob.centerY)
        let camY = Double(snapshot.cameraToWorld.columns.3.y)
        let fallbackY = snapshot.currentBall?.worldY ?? (camY - 1.30)
        return GolfBallWorldLocalizer.localize(
            imageX: source.x,
            imageY: source.y,
            imageWidth: snapshot.sourceWidth,
            imageHeight: snapshot.sourceHeight,
            sourceWidth: snapshot.sourceWidth,
            sourceHeight: snapshot.sourceHeight,
            rgbIntrinsics: snapshot.rgbIntrinsics,
            cameraToWorld: snapshot.cameraToWorld,
            groundYSamples: ring.groundY,
            fallbackGroundY: fallbackY,
            expectedWorldX: snapshot.currentBall?.worldX,
            expectedWorldZ: snapshot.currentBall?.worldZ
        )
    }

    private static func aimPointInCapturedImage(
        frame: ARFrame,
        currentBall: ScanPose?,
        viewport: CGSize,
        orientation: UIInterfaceOrientation,
        bufferWidth: Int,
        bufferHeight: Int
    ) -> (x: Double, y: Double) {
        let sourceSize = frame.camera.imageResolution
        let scaleX = Double(bufferWidth) / Double(max(sourceSize.width, 1))
        let scaleY = Double(bufferHeight) / Double(max(sourceSize.height, 1))
        let opticalX = Double(frame.camera.intrinsics[2, 0]) * scaleX
        let opticalY = Double(frame.camera.intrinsics[2, 1]) * scaleY

        if let currentBall,
           let projected = capturedImagePoint(
            world: SIMD3<Float>(
                Float(currentBall.worldX),
                Float(currentBall.worldY + GolfBallVisualLock.radiusMeters),
                Float(currentBall.worldZ)
            ),
            camera: frame.camera
           ) {
            return (projected.x * scaleX, projected.y * scaleY)
        }

        if let currentBall {
            let cam = frame.camera.transform.columns.3
            let ball = SIMD3<Float>(
                Float(currentBall.worldX),
                Float(currentBall.worldY + GolfBallVisualLock.radiusMeters),
                Float(currentBall.worldZ)
            )
            let toBall = ball - SIMD3<Float>(cam.x, cam.y, cam.z)
            if simd_length(toBall) > 0.08,
               let alongView = capturedImagePoint(
                world: SIMD3<Float>(cam.x, cam.y, cam.z) + simd_normalize(toBall) * 0.6,
                camera: frame.camera
               ) {
                return (alongView.x * scaleX, alongView.y * scaleY)
            }
        }

        // 볼 지정 raycast와 같은 광축. 스캔 시작(월드 볼 없음)에서만 십자선.
        var aimX = opticalX
        var aimY = opticalY
        if viewport.width > 1, viewport.height > 1 {
            let transform = frame.displayTransform(for: orientation, viewportSize: viewport)
            let imageNorm = CGPoint(x: 0.5, y: 0.5).applying(transform.inverted())
            if imageNorm.x.isFinite, imageNorm.y.isFinite {
                let viewX = Double(imageNorm.x) * Double(bufferWidth)
                let viewY = Double(imageNorm.y) * Double(bufferHeight)
                let drift = hypot(viewX - opticalX, viewY - opticalY)
                if drift < Double(min(bufferWidth, bufferHeight)) * 0.22 {
                    aimX = (viewX + opticalX) * 0.5
                    aimY = (viewY + opticalY) * 0.5
                }
            }
        }
        return (
            min(max(aimX, 0), Double(bufferWidth) - 1),
            min(max(aimY, 0), Double(bufferHeight) - 1)
        )
    }

    private static func capturedImagePoint(
        world: SIMD3<Float>,
        camera: ARCamera
    ) -> (x: Double, y: Double)? {
        let local = camera.transform.inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
        guard local.z < -0.25 else { return nil }
        let fx = Double(camera.intrinsics[0, 0])
        let fy = Double(camera.intrinsics[1, 1])
        let cx = Double(camera.intrinsics[2, 0])
        let cy = Double(camera.intrinsics[2, 1])
        let x = fx * Double(local.x / -local.z) + cx
        let y = -fy * Double(local.y / -local.z) + cy
        let size = camera.imageResolution
        guard x.isFinite, y.isFinite else { return nil }
        let margin = 0.22 * max(size.width, size.height)
        guard x >= -margin, y >= -margin,
              x <= Double(size.width) + margin,
              y <= Double(size.height) + margin
        else { return nil }
        return (
            min(max(x, 0), Double(size.width) - 1),
            min(max(y, 0), Double(size.height) - 1)
        )
    }

    private static func sampleDepthMeters(
        frame: ARFrame,
        sourceX: Double,
        sourceY: Double
    ) -> Double? {
        guard let depthData = frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 4, height > 4, let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let imageSize = frame.camera.imageResolution
        let dx = sourceX * Double(width) / Double(max(imageSize.width, 1))
        let dy = sourceY * Double(height) / Double(max(imageSize.height, 1))
        var samples: [Float] = []
        let radius = 6
        for y in (Int(dy) - radius)...(Int(dy) + radius) {
            guard y >= 0, y < height else { continue }
            let row = UnsafeRawPointer(base)
                .advanced(by: bytesPerRow * y)
                .assumingMemoryBound(to: Float32.self)
            for x in (Int(dx) - radius)...(Int(dx) + radius) {
                guard x >= 0, x < width else { continue }
                let d = row[x]
                if d.isFinite, d >= 0.45, d <= 3.8 {
                    samples.append(d)
                }
            }
        }
        guard samples.count >= 4 else { return nil }
        samples.sort()
        return Double(samples[samples.count / 2])
    }

    private static func extractPatch(
        _ pixelBuffer: CVPixelBuffer,
        centerX: Double,
        centerY: Double,
        patchSize: Int
    ) -> (image: GolfBallImageBuffer, originX: Int, originY: Int)? {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 16, srcH > 16, patchSize >= 32 else { return nil }
        let size = min(patchSize, min(srcW, srcH) & ~1)
        var x0 = Int(centerX.rounded()) - size / 2
        var y0 = Int(centerY.rounded()) - size / 2
        x0 = max(0, min(srcW - size, x0)) & ~1
        y0 = max(0, min(srcH - size, y0)) & ~1
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let image: GolfBallImageBuffer?
        if planeCount >= 2 {
            image = extractPatch420(
                pixelBuffer,
                originX: x0,
                originY: y0,
                width: size,
                height: size,
                videoRange: isVideoRange420(format)
            )
        } else if format == kCVPixelFormatType_32BGRA {
            image = extractPatchBGRA(pixelBuffer, originX: x0, originY: y0, width: size, height: size)
        } else {
            image = nil
        }
        guard let image else { return nil }
        return (image, x0, y0)
    }

    private static func extractPatch420(
        _ pixelBuffer: CVPixelBuffer,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        videoRange: Bool
    ) -> GolfBallImageBuffer? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)
        var luma = [UInt8](repeating: 0, count: width * height)
        var sat = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = originY + y
            let yRow = yPtr.advanced(by: sy * yStride)
            let uvRow = uvPtr.advanced(by: (sy / 2) * uvStride)
            let outRow = y * width
            for x in 0..<width {
                let sx = originX + x
                var yv = Int(yRow[sx])
                if videoRange {
                    yv = min(255, max(0, (yv - 16) * 255 / 219))
                }
                luma[outRow + x] = UInt8(yv)
                let uvx = (sx / 2) * 2
                let cb = Int(uvRow[uvx])
                let cr = Int(uvRow[uvx + 1])
                let chroma = hypot(Double(cb - 128), Double(cr - 128))
                sat[outRow + x] = UInt8(min(255, chroma * 1.6))
            }
        }
        return GolfBallImageBuffer(width: width, height: height, luma: luma, saturation: sat)
    }

    private static func extractPatchBGRA(
        _ pixelBuffer: CVPixelBuffer,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> GolfBallImageBuffer? {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var luma = [UInt8](repeating: 0, count: width * height)
        var sat = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = ptr.advanced(by: (originY + y) * stride)
            let outRow = y * width
            for x in 0..<width {
                let p = row.advanced(by: (originX + x) * 4)
                let b = Double(p[0])
                let g = Double(p[1])
                let r = Double(p[2])
                let yv = 0.299 * r + 0.587 * g + 0.114 * b
                luma[outRow + x] = UInt8(min(255, max(0, yv)))
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let s = maxC <= 1 ? 0 : (maxC - minC) / maxC * 255
                sat[outRow + x] = UInt8(min(255, s))
            }
        }
        return GolfBallImageBuffer(width: width, height: height, luma: luma, saturation: sat)
    }

    private static func downsampleCapturedImage(
        _ pixelBuffer: CVPixelBuffer,
        targetWidth: Int
    ) -> GolfBallImageBuffer? {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 8, srcH > 8 else { return nil }
        let outW = min(targetWidth, srcW)
        let outH = max(1, srcH * outW / srcW)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        if planeCount >= 2 {
            return downsample420(
                pixelBuffer,
                srcW: srcW,
                srcH: srcH,
                outW: outW,
                outH: outH,
                videoRange: isVideoRange420(format)
            )
        }
        if format == kCVPixelFormatType_32BGRA {
            return downsampleBGRA(pixelBuffer, srcW: srcW, srcH: srcH, outW: outW, outH: outH)
        }
        return nil
    }

    private static func isVideoRange420(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange:
            return true
        default:
            return false
        }
    }

    private static func downsample420(
        _ pixelBuffer: CVPixelBuffer,
        srcW: Int,
        srcH: Int,
        outW: Int,
        outH: Int,
        videoRange: Bool
    ) -> GolfBallImageBuffer? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        var luma = [UInt8](repeating: 0, count: outW * outH)
        var sat = [UInt8](repeating: 0, count: outW * outH)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)
        for oy in 0..<outH {
            let y0 = oy * srcH / outH
            let y1 = min(srcH, max(y0 + 1, (oy + 1) * srcH / outH))
            let outRow = oy * outW
            for ox in 0..<outW {
                let x0 = ox * srcW / outW
                let x1 = min(srcW, max(x0 + 1, (ox + 1) * srcW / outW))
                var bestY = 0
                var bestSX = x0
                var bestSY = y0
                for sy in y0..<y1 {
                    let yRow = yPtr.advanced(by: sy * yStride)
                    for sx in x0..<x1 {
                        let yv = Int(yRow[sx])
                        if yv >= bestY {
                            bestY = yv
                            bestSX = sx
                            bestSY = sy
                        }
                    }
                }
                if videoRange {
                    bestY = min(255, max(0, (bestY - 16) * 255 / 219))
                }
                luma[outRow + ox] = UInt8(bestY)
                let uvRow = uvPtr.advanced(by: (bestSY / 2) * uvStride)
                let uvx = (bestSX / 2) * 2
                let cb = Int(uvRow[uvx])
                let cr = Int(uvRow[uvx + 1])
                let chroma = hypot(Double(cb - 128), Double(cr - 128))
                sat[outRow + ox] = UInt8(min(255, chroma * 1.6))
            }
        }
        return GolfBallImageBuffer(width: outW, height: outH, luma: luma, saturation: sat)
    }

    private static func downsampleBGRA(
        _ pixelBuffer: CVPixelBuffer,
        srcW: Int,
        srcH: Int,
        outW: Int,
        outH: Int
    ) -> GolfBallImageBuffer? {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var luma = [UInt8](repeating: 0, count: outW * outH)
        var sat = [UInt8](repeating: 0, count: outW * outH)
        for oy in 0..<outH {
            let y0 = oy * srcH / outH
            let y1 = min(srcH, max(y0 + 1, (oy + 1) * srcH / outH))
            let outRow = oy * outW
            for ox in 0..<outW {
                let x0 = ox * srcW / outW
                let x1 = min(srcW, max(x0 + 1, (ox + 1) * srcW / outW))
                var bestY = -1.0
                var bestR = 0.0
                var bestG = 0.0
                var bestB = 0.0
                for sy in y0..<y1 {
                    let row = ptr.advanced(by: sy * stride)
                    for sx in x0..<x1 {
                        let p = row.advanced(by: sx * 4)
                        let b = Double(p[0])
                        let g = Double(p[1])
                        let r = Double(p[2])
                        let y = 0.299 * r + 0.587 * g + 0.114 * b
                        if y >= bestY {
                            bestY = y
                            bestR = r
                            bestG = g
                            bestB = b
                        }
                    }
                }
                luma[outRow + ox] = UInt8(min(255, max(0, bestY)))
                let maxC = max(bestR, max(bestG, bestB))
                let minC = min(bestR, min(bestG, bestB))
                let s = maxC <= 1 ? 0 : (maxC - minC) / maxC * 255
                sat[outRow + ox] = UInt8(min(255, s))
            }
        }
        return GolfBallImageBuffer(width: outW, height: outH, luma: luma, saturation: sat)
    }

    private static func copyDepthPatch(
        _ frame: ARFrame,
        sourceX: Double,
        sourceY: Double,
        radiusSourcePixels: Double
    ) -> CopiedDepth? {
        guard let depthData = frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let mapWidth = CVPixelBufferGetWidth(depthMap)
        let mapHeight = CVPixelBufferGetHeight(depthMap)
        guard mapWidth > 8, mapHeight > 8, let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        let imageSize = frame.camera.imageResolution
        let cx = sourceX * Double(mapWidth) / Double(max(imageSize.width, 1))
        let cy = sourceY * Double(mapHeight) / Double(max(imageSize.height, 1))
        let radius = Int(max(14, radiusSourcePixels * Double(mapWidth) / Double(max(imageSize.width, 1))))
        let x0 = max(0, Int(cx) - radius)
        let x1 = min(mapWidth - 1, Int(cx) + radius)
        let y0 = max(0, Int(cy) - radius)
        let y1 = min(mapHeight - 1, Int(cy) + radius)
        let patchW = x1 - x0 + 1
        let patchH = y1 - y0 + 1
        guard patchW > 4, patchH > 4 else { return nil }

        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceBytesPerRow = 0
        if let confidenceMap = depthData.confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap)
            confidenceBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if let confidenceMap = depthData.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        var depths = [Float](repeating: 0, count: patchW * patchH)
        var confidence = [UInt8](repeating: 2, count: patchW * patchH)
        for py in 0..<patchH {
            let sy = y0 + py
            let depthRow = UnsafeRawPointer(base)
                .advanced(by: bytesPerRow * sy)
                .assumingMemoryBound(to: Float32.self)
            let confRow: UnsafePointer<UInt8>? = {
                guard let confidenceBase else { return nil }
                return UnsafeRawPointer(confidenceBase)
                    .advanced(by: confidenceBytesPerRow * sy)
                    .assumingMemoryBound(to: UInt8.self)
            }()
            let outRow = py * patchW
            for px in 0..<patchW {
                let sx = x0 + px
                depths[outRow + px] = depthRow[sx]
                confidence[outRow + px] = confRow?[sx] ?? 2
            }
        }

        let scaleX = Float(mapWidth) / Float(max(imageSize.width, 1))
        let scaleY = Float(mapHeight) / Float(max(imageSize.height, 1))
        var depthIntrinsics = frame.camera.intrinsics
        depthIntrinsics[0, 0] *= scaleX
        depthIntrinsics[1, 1] *= scaleY
        depthIntrinsics[2, 0] *= scaleX
        depthIntrinsics[2, 1] *= scaleY
        return CopiedDepth(
            width: patchW,
            height: patchH,
            originX: x0,
            originY: y0,
            mapWidth: mapWidth,
            mapHeight: mapHeight,
            depths: depths,
            confidence: confidence,
            intrinsics: depthIntrinsics,
            cameraToWorld: frame.camera.transform
        )
    }

    private static func copyDepth(_ frame: ARFrame) -> CopiedDepth? {
        guard let depthData = frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 4, height > 4, let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceBytesPerRow = 0
        if let confidenceMap = depthData.confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap)
            confidenceBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if let confidenceMap = depthData.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        var depths = [Float](repeating: 0, count: width * height)
        var confidence = [UInt8](repeating: 2, count: width * height)
        for y in 0..<height {
            let depthRow = UnsafeRawPointer(base)
                .advanced(by: bytesPerRow * y)
                .assumingMemoryBound(to: Float32.self)
            let confRow: UnsafePointer<UInt8>? = {
                guard let confidenceBase else { return nil }
                return UnsafeRawPointer(confidenceBase)
                    .advanced(by: confidenceBytesPerRow * y)
                    .assumingMemoryBound(to: UInt8.self)
            }()
            let outRow = y * width
            for x in 0..<width {
                depths[outRow + x] = depthRow[x]
                confidence[outRow + x] = confRow?[x] ?? 2
            }
        }

        let imageSize = frame.camera.imageResolution
        let scaleX = Float(width) / Float(max(imageSize.width, 1))
        let scaleY = Float(height) / Float(max(imageSize.height, 1))
        var depthIntrinsics = frame.camera.intrinsics
        depthIntrinsics[0, 0] *= scaleX
        depthIntrinsics[1, 1] *= scaleY
        depthIntrinsics[2, 0] *= scaleX
        depthIntrinsics[2, 1] *= scaleY
        return CopiedDepth(
            width: width,
            height: height,
            originX: 0,
            originY: 0,
            mapWidth: width,
            mapHeight: height,
            depths: depths,
            confidence: confidence,
            intrinsics: depthIntrinsics,
            cameraToWorld: frame.camera.transform
        )
    }

    private struct DepthRing {
        var groundY: [Double]
        var medianDepth: Float?
    }

    private static func depthRing(around blob: GolfBallBlob, snapshot: Snapshot) -> DepthRing {
        guard let depth = snapshot.depth else { return DepthRing(groundY: [], medianDepth: nil) }
        let source = snapshot.sourcePixel(x: blob.centerX, y: blob.centerY)
        let gx = source.x * Double(depth.mapWidth) / Double(max(snapshot.sourceWidth, 1))
        let gy = source.y * Double(depth.mapHeight) / Double(max(snapshot.sourceHeight, 1))
        let sx = gx - Double(depth.originX)
        let sy = gy - Double(depth.originY)
        let sr = max(
            3.0,
            blob.radiusPixels * snapshot.detectionToSource * Double(depth.mapWidth)
                / Double(max(snapshot.sourceWidth, 1))
        )
        let inner = sr * 1.5
        let outer = max(sr * 3.6, 9)
        var depths: [Float] = []
        var worlds: [(worldX: Double, worldY: Double, worldZ: Double)] = []
        let x0 = max(0, Int(sx - outer))
        let x1 = min(depth.width - 1, Int(sx + outer))
        let y0 = max(0, Int(sy - outer))
        let y1 = min(depth.height - 1, Int(sy + outer))
        let step = max(1, (x1 - x0) / 24)
        for y in stride(from: y0, through: y1, by: step) {
            for x in stride(from: x0, through: x1, by: step) {
                let dx = Double(x) - sx
                let dy = Double(y) - sy
                let r = hypot(dx, dy)
                guard r >= inner, r <= outer else { continue }
                let idx = y * depth.width + x
                if depth.confidence[idx] < ScanCoverage.minConfidence { continue }
                let d = depth.depths[idx]
                guard d.isFinite, d >= ScanCoverage.minDepthMeters, d <= ScanCoverage.maxDepthMeters else {
                    continue
                }
                depths.append(d)
                let wx = Double(x + depth.originX)
                let wy = Double(y + depth.originY)
                if let world = ScanCoverage.unproject(
                    depthX: Float(wx),
                    depthY: Float(wy),
                    depthMeters: d,
                    intrinsics: depth.intrinsics,
                    cameraToWorld: depth.cameraToWorld
                ) {
                    worlds.append(
                        (worldX: Double(world.x), worldY: Double(world.y), worldZ: Double(world.z))
                    )
                }
            }
        }
        let medianDepth: Float? = {
            guard !depths.isEmpty else { return nil }
            let sorted = depths.sorted()
            return sorted[sorted.count / 2]
        }()
        var groundY: [Double] = []
        if let current = snapshot.currentBall {
            groundY = GolfBallWorldLocalizer.filterGroundRingY(
                samples: worlds,
                expectedX: current.worldX,
                expectedY: current.worldY,
                expectedZ: current.worldZ
            )
        }
        if groundY.isEmpty {
            groundY = worlds.map(\.worldY)
        }
        return DepthRing(groundY: groundY, medianDepth: medianDepth)
    }
}
