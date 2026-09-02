import Foundation
import simd

/// 조준 중 RGB에서 흰 골프공을 찾고, LiDAR 지면 높이로 월드 좌표를 붙인다.
///
/// 제3자 제약:
/// - LiDAR 픽셀은 공보다 커서 공 중심 깊이는 잔디 뒤로 뚫린다. 공 픽셀 depth는 쓰지 않는다.
/// - RGB는 원반 위치, LiDAR는 공 주변 고리의 지면 Y.
/// - 물리 높이맵 원점은 스캔 볼에 고정. 이 모듈은 AR 볼(조준 프레임)만 맞춘다.
public enum GolfBallVisualLock {
    public static let diameterMeters = 0.04267
    public static let radiusMeters = diameterMeters * 0.5
    /// AR 볼과 이보다 가까우면 이미 일치로 본다.
    public static let alignSlopMeters = 0.018
    /// 잠긴 뒤 이보다 덜 움직이면 조준선을 다시 안 옮긴다.
    public static let relockDeadzoneMeters = 0.025
    /// 현재 AR 볼에서 이보다 먼 후보는 다른 흰 물체로 본다.
    public static let maxOffsetFromARBallMeters = 0.42
    /// 스캔 당시 볼(물리 원점)에서 이보다 멀면 오탐/다른 볼.
    public static let maxOffsetFromPhysicsMeters = 0.55
}

public struct GolfBallImageBuffer: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// row-major, 0...255
    public var luma: [UInt8]
    /// chroma magnitude proxy, 0...255. 흰색은 낮고 잔디는 높다.
    public var saturation: [UInt8]

    public init(width: Int, height: Int, luma: [UInt8], saturation: [UInt8]) {
        self.width = width
        self.height = height
        self.luma = luma
        self.saturation = saturation
    }
}

public struct GolfBallDetectionHint: Sendable, Equatable {
    /// 감지 이미지 픽셀. AR 볼 투영. 없으면 화면 중앙.
    public var expectedCenterX: Double
    public var expectedCenterY: Double
    public var expectedRadiusPixels: Double
    public var searchRadiusPixels: Double
    /// 스캔 시작처럼 AR 볼이 없을 때 — 픽셀 반지름 비율을 느슨히.
    public var looseSize: Bool
    /// 전체 프레임 탐색일 때만 상단(하늘)을 버린다. 십자선 크롭에서는 끄다.
    public var rejectSkyBand: Bool

    public var minRadiusPixels: Double
    public var maxRadiusPixels: Double

    public init(
        expectedCenterX: Double,
        expectedCenterY: Double,
        expectedRadiusPixels: Double,
        searchRadiusPixels: Double,
        looseSize: Bool = false,
        minRadiusPixels: Double = 0,
        maxRadiusPixels: Double = 0,
        rejectSkyBand: Bool = true
    ) {
        self.expectedCenterX = expectedCenterX
        self.expectedCenterY = expectedCenterY
        self.expectedRadiusPixels = expectedRadiusPixels
        self.searchRadiusPixels = searchRadiusPixels
        self.looseSize = looseSize
        self.minRadiusPixels = minRadiusPixels
        self.maxRadiusPixels = maxRadiusPixels
        self.rejectSkyBand = rejectSkyBand
    }

    /// 스캔 시작: 서서 1.2–1.4m, 숙여서 ~0.5m까지. 발밑 가까운 깊이로 최소 크기를 키우지 않는다.
    public static func openSearch(
        width: Int,
        height: Int,
        expectedRadiusPixels: Double? = nil,
        focalX: Double? = nil
    ) -> GolfBallDetectionHint {
        let w = Double(max(width, 1))
        let h = Double(max(height, 1))
        let short = min(w, h)
        let standing = focalX.map {
            GolfBallWorldLocalizer.expectedRadiusPixels(focalX: $0, distanceMeters: 1.3)
        } ?? max(5.2, 0.0115 * short)
        let expected: Double = {
            guard let given = expectedRadiusPixels else { return standing }
            return min(max(given, standing * 0.75), standing * 1.25)
        }()
        let closeDisk = focalX.map {
            GolfBallWorldLocalizer.expectedRadiusPixels(focalX: $0, distanceMeters: 0.5)
        } ?? max(standing * 2.6, 22)
        return GolfBallDetectionHint(
            expectedCenterX: w * 0.5,
            expectedCenterY: h * 0.58,
            expectedRadiusPixels: expected,
            searchRadiusPixels: hypot(w, h) * 0.62,
            looseSize: true,
            minRadiusPixels: max(3.2, standing * 0.42),
            maxRadiusPixels: min(0.32 * short, max(closeDisk, 28))
        )
    }

    /// 십자선(또는 AR 볼 투영) 근처만. 크롭 버퍼 기준으로 쓴다.
    public static func aroundReticle(
        centerX: Double,
        centerY: Double,
        width: Int,
        height: Int,
        expectedRadiusPixels: Double,
        farRadiusPixels: Double? = nil
    ) -> GolfBallDetectionHint {
        let w = Double(max(width, 1))
        let h = Double(max(height, 1))
        let short = min(w, h)
        let expected = max(4.0, expectedRadiusPixels)
        let far = max(3.5, farRadiusPixels ?? expected * 0.78)
        return GolfBallDetectionHint(
            expectedCenterX: centerX,
            expectedCenterY: centerY,
            expectedRadiusPixels: expected,
            searchRadiusPixels: short * 0.50,
            looseSize: true,
            minRadiusPixels: max(2.8, far * 0.22),
            maxRadiusPixels: min(0.50 * short, max(expected * 3.0, 48)),
            rejectSkyBand: false
        )
    }

    /// 스캔·조준에서 이미 알고 있는 월드 볼 위치를 화면에 투영했을 때 — 십자선보다 탐색 반경을 좁힌다.
    public static func aroundWorldAnchor(
        centerX: Double,
        centerY: Double,
        width: Int,
        height: Int,
        expectedRadiusPixels: Double,
        distanceMeters: Double,
        farRadiusPixels: Double? = nil
    ) -> GolfBallDetectionHint {
        let w = Double(max(width, 1))
        let h = Double(max(height, 1))
        let short = min(w, h)
        let expected = max(4.0, expectedRadiusPixels)
        let far = max(3.5, farRadiusPixels ?? expected * 0.78)
        let searchScale: Double
        if distanceMeters < 0.75 {
            searchScale = 0.26
        } else if distanceMeters < 1.35 {
            searchScale = 0.34
        } else {
            searchScale = 0.42
        }
        return GolfBallDetectionHint(
            expectedCenterX: centerX,
            expectedCenterY: centerY,
            expectedRadiusPixels: expected,
            searchRadiusPixels: short * searchScale,
            looseSize: true,
            minRadiusPixels: max(2.8, far * 0.22),
            maxRadiusPixels: min(0.44 * short, max(expected * 2.6, 42)),
            rejectSkyBand: false
        )
    }
}

public struct GolfBallBlob: Sendable, Equatable {
    public var centerX: Double
    public var centerY: Double
    public var radiusPixels: Double
    public var score: Double
    public var pixelCount: Int

    public init(centerX: Double, centerY: Double, radiusPixels: Double, score: Double, pixelCount: Int) {
        self.centerX = centerX
        self.centerY = centerY
        self.radiusPixels = radiusPixels
        self.score = score
        self.pixelCount = pixelCount
    }
}

public struct GolfBallWorldContact: Sendable, Equatable {
    public var worldX: Double
    public var worldY: Double
    public var worldZ: Double
    public var confidence: Double

    public init(worldX: Double, worldY: Double, worldZ: Double, confidence: Double) {
        self.worldX = worldX
        self.worldY = worldY
        self.worldZ = worldZ
        self.confidence = confidence
    }
}

public enum GolfBallLockAction: Sendable, Equatable {
    case none
    /// 이미 AR 볼과 맞음. 수동 재지정 플래그만 내려도 된다.
    case confirmAligned
    case apply(GolfBallWorldContact)
}

/// 흰 원형 + 어두운(잔디) 고리.
public enum GolfBallRGBDetector {
    public static let minLuma: UInt8 = 148
    public static let maxSaturation: UInt8 = 84
    public static let minScore = 0.52

    public static func detect(
        image: GolfBallImageBuffer,
        hint: GolfBallDetectionHint
    ) -> GolfBallBlob? {
        if hint.rejectSkyBand == false {
            return GolfBallFastDetector.detect(image: image, hint: hint)
                ?? detectAdaptive(image: image, hint: hint)
        }
        return detect(image: image, hint: hint, lumaFloor: 165, satCeil: 68)
            ?? detect(image: image, hint: hint, lumaFloor: Int(minLuma), satCeil: Int(maxSaturation))
    }

    /// 십자선 창: 주변 그린보다 밝은 덩어리를 공으로 본다. 채도 흰색만 쓰면 실외 공이 탈락한다.
    private static func detectAdaptive(
        image: GolfBallImageBuffer,
        hint: GolfBallDetectionHint
    ) -> GolfBallBlob? {
        let width = image.width
        let height = image.height
        guard width >= 16, height >= 16,
              image.luma.count >= width * height
        else { return nil }

        let searchR = max(hint.searchRadiusPixels, hint.expectedRadiusPixels * 2.5)
        let x0 = max(0, Int(floor(hint.expectedCenterX - searchR)))
        let x1 = min(width - 1, Int(ceil(hint.expectedCenterX + searchR)))
        let y0 = max(0, Int(floor(hint.expectedCenterY - searchR)))
        let y1 = min(height - 1, Int(ceil(hint.expectedCenterY + searchR)))
        guard x1 > x0 + 2, y1 > y0 + 2 else { return nil }

        var samples: [UInt8] = []
        samples.reserveCapacity(256)
        for y in stride(from: y0, through: y1, by: 2) {
            let row = y * width
            for x in stride(from: x0, through: x1, by: 2) {
                samples.append(image.luma[row + x])
            }
        }
        guard samples.count >= 16 else { return nil }
        samples.sort()
        let grass = Int(samples[samples.count * 2 / 5])
        let floor = min(190, max(135, grass + 36))

        let roiW = x1 - x0 + 1
        let roiH = y1 - y0 + 1
        let roiPixels = roiW * roiH
        var mask = [UInt8](repeating: 0, count: roiPixels)
        var whiteCount = 0
        for y in y0...y1 {
            let srcRow = y * width
            let maskRow = (y - y0) * roiW
            for x in x0...x1 {
                let i = srcRow + x
                let yv = Int(image.luma[i])
                let sat = image.saturation.indices.contains(i) ? Int(image.saturation[i]) : 0
                // 잔디 반사(채도 높음)는 제외. 진짜 흰 공만.
                if yv >= floor, sat <= 110 {
                    mask[maskRow + (x - x0)] = 1
                    whiteCount += 1
                }
            }
        }
        if whiteCount < 12 || whiteCount > roiPixels * 2 / 5 {
            return nil
        }

        var visited = [UInt8](repeating: 0, count: roiPixels)
        var best: GolfBallBlob?
        var stack = [Int]()
        stack.reserveCapacity(64)
        for seed in 0..<roiPixels where mask[seed] == 1 && visited[seed] == 0 {
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            visited[seed] = 1
            var pixels: [Int] = [seed]
            pixels.reserveCapacity(32)
            var head = 0
            while head < stack.count {
                let idx = stack[head]
                head += 1
                let lx = idx % roiW
                let ly = idx / roiW
                for (nx, ny) in [(lx - 1, ly), (lx + 1, ly), (lx, ly - 1), (lx, ly + 1)] {
                    guard nx >= 0, ny >= 0, nx < roiW, ny < roiH else { continue }
                    let nidx = ny * roiW + nx
                    if mask[nidx] == 1, visited[nidx] == 0 {
                        visited[nidx] = 1
                        stack.append(nidx)
                        pixels.append(nidx)
                    }
                }
            }
            guard let blob = scoreBlob(
                pixels: pixels,
                roiW: roiW,
                originX: x0,
                originY: y0,
                image: image,
                hint: hint
            ) else { continue }
            if blob.score > (best?.score ?? 0) {
                best = blob
            }
        }
        guard let best, best.score >= minScore else { return nil }
        return best
    }

    private static func detect(
        image: GolfBallImageBuffer,
        hint: GolfBallDetectionHint,
        lumaFloor: Int,
        satCeil: Int
    ) -> GolfBallBlob? {
        let width = image.width
        let height = image.height
        guard width >= 16, height >= 16,
              image.luma.count >= width * height,
              image.saturation.count >= width * height
        else { return nil }

        let searchR = max(hint.searchRadiusPixels, hint.expectedRadiusPixels * 2.5)
        let x0 = max(0, Int(floor(hint.expectedCenterX - searchR)))
        let x1 = min(width - 1, Int(ceil(hint.expectedCenterX + searchR)))
        let y0 = max(0, Int(floor(hint.expectedCenterY - searchR)))
        let y1 = min(height - 1, Int(ceil(hint.expectedCenterY + searchR)))
        guard x1 > x0 + 2, y1 > y0 + 2 else { return nil }

        let roiW = x1 - x0 + 1
        let roiH = y1 - y0 + 1
        let roiPixels = roiW * roiH
        var mask = [UInt8](repeating: 0, count: roiPixels)
        var whiteCount = 0
        for y in y0...y1 {
            let srcRow = y * width
            let maskRow = (y - y0) * roiW
            for x in x0...x1 {
                let i = srcRow + x
                let yv = Int(image.luma[i])
                let sat = Int(image.saturation[i])
                // 채도가 높은 픽셀은 잔디. 로컬 대비만 쓰면 그린 전체가 마스크가 된다.
                if yv >= lumaFloor, sat <= satCeil {
                    mask[maskRow + (x - x0)] = 1
                    whiteCount += 1
                }
            }
        }
        // 과노출만 포기. 그린 텍스처 때문에 중간 밀도로 버리지 않는다.
        if whiteCount < 8 || whiteCount > roiPixels * 4 / 5 {
            return nil
        }

        var visited = [UInt8](repeating: 0, count: roiPixels)
        var best: GolfBallBlob?
        var stack = [Int]()
        stack.reserveCapacity(64)

        for seed in 0..<roiPixels where mask[seed] == 1 && visited[seed] == 0 {
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            visited[seed] = 1
            var pixels: [Int] = [seed]
            pixels.reserveCapacity(32)
            var head = 0
            while head < stack.count {
                let idx = stack[head]
                head += 1
                let lx = idx % roiW
                let ly = idx / roiW
                let neighbors = [
                    (lx - 1, ly), (lx + 1, ly), (lx, ly - 1), (lx, ly + 1)
                ]
                for (nx, ny) in neighbors {
                    guard nx >= 0, ny >= 0, nx < roiW, ny < roiH else { continue }
                    let nidx = ny * roiW + nx
                    if mask[nidx] == 1, visited[nidx] == 0 {
                        visited[nidx] = 1
                        stack.append(nidx)
                        pixels.append(nidx)
                    }
                }
            }
            guard let blob = scoreBlob(
                pixels: pixels,
                roiW: roiW,
                originX: x0,
                originY: y0,
                image: image,
                hint: hint
            ) else { continue }
            if blob.score > (best?.score ?? 0) {
                best = blob
            }
        }
        guard let best, best.score >= minScore else { return nil }
        return best
    }

    private static func scoreBlob(
        pixels: [Int],
        roiW: Int,
        originX: Int,
        originY: Int,
        image: GolfBallImageBuffer,
        hint: GolfBallDetectionHint
    ) -> GolfBallBlob? {
        let count = pixels.count
        let minR = hint.minRadiusPixels > 0 ? hint.minRadiusPixels : (hint.looseSize ? 3.2 : 2.4)
        let maxR = hint.maxRadiusPixels > 0 ? hint.maxRadiusPixels : max(hint.expectedRadiusPixels * 3, 48)
        let minPixels = max(hint.rejectSkyBand ? 12 : 8, Int(Double.pi * minR * minR * 0.24))
        guard count >= minPixels, count <= 12_000 else { return nil }

        var sumX = 0.0
        var sumY = 0.0
        var minX = Int.max
        var maxX = Int.min
        var minY = Int.max
        var maxY = Int.min
        var lumaSum = 0
        for idx in pixels {
            let lx = idx % roiW
            let ly = idx / roiW
            let x = originX + lx
            let y = originY + ly
            sumX += Double(x)
            sumY += Double(y)
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            lumaSum += Int(image.luma[y * image.width + x])
        }
        let cx = sumX / Double(count)
        let cy = sumY / Double(count)
        let bw = Double(maxX - minX + 1)
        let bh = Double(maxY - minY + 1)
        let aspect = min(bw, bh) / max(bw, bh)
        guard aspect >= (hint.looseSize ? 0.66 : 0.72) else { return nil }

        var radiusSum = 0.0
        var radiusSq = 0.0
        for idx in pixels {
            let x = Double(originX + idx % roiW)
            let y = Double(originY + idx / roiW)
            let r = hypot(x - cx, y - cy)
            radiusSum += r
            radiusSq += r * r
        }
        let radiusMean = radiusSum / Double(count)
        guard radiusMean >= minR, radiusMean <= maxR else { return nil }
        let variance = max(0, radiusSq / Double(count) - radiusMean * radiusMean)
        let radiusStd = sqrt(variance)
        let circularity = 1 - min(1, radiusStd / max(radiusMean, 0.8))
        guard circularity >= (hint.looseSize ? 0.40 : 0.52) else { return nil }
        if hint.rejectSkyBand, cy < Double(image.height) * 0.12 {
            return nil
        }

        let blobLuma = Double(lumaSum) / Double(count)
        guard blobLuma >= (hint.rejectSkyBand ? 150 : 132) else { return nil }

        let areaFit = {
            let expectedArea = Double.pi * radiusMean * radiusMean
            return 1 - min(1, abs(Double(count) - expectedArea) / max(expectedArea, 1))
        }()

        let sizeFit: Double = {
            let expected = max(hint.expectedRadiusPixels, minR)
            let ratio = radiusMean / expected
            if hint.looseSize {
                return 1 - min(1, abs(log(max(ratio, 0.05))) / 1.7)
            }
            if ratio < 0.40 || ratio > 2.7 { return 0 }
            return 1 - min(1, abs(log(ratio)) / 1.15)
        }()
        if !hint.looseSize {
            guard sizeFit > 0.18 else { return nil }
        }

        let dist = hypot(cx - hint.expectedCenterX, cy - hint.expectedCenterY)
        let proximity = 1 - min(1, dist / max(hint.searchRadiusPixels, 8))

        let contrast = ringContrast(
            cx: cx,
            cy: cy,
            radius: radiusMean,
            blobLuma: blobLuma,
            image: image,
            ringScale: hint.rejectSkyBand ? 1.85 : 2.55,
            deltaFloor: hint.rejectSkyBand ? 28 : 12
        )
        guard contrast >= (hint.rejectSkyBand ? (hint.looseSize ? 0.24 : 0.32) : 0.22) else { return nil }

        let proxW = hint.rejectSkyBand ? 0.08 : 0.24
        let contrastW = hint.rejectSkyBand ? 0.32 : 0.20
        let circW = hint.rejectSkyBand ? 0.30 : 0.26
        let score = circW * circularity
            + 0.12 * areaFit
            + 0.18 * sizeFit
            + proxW * proximity
            + contrastW * contrast
        return GolfBallBlob(
            centerX: cx,
            centerY: cy,
            radiusPixels: radiusMean,
            score: score,
            pixelCount: count
        )
    }

    /// 공 주변이 공보다 어두워야 한다(그린). 하늘·흰 신발은 고리도 밝다.
    private static func ringContrast(
        cx: Double,
        cy: Double,
        radius: Double,
        blobLuma: Double,
        image: GolfBallImageBuffer,
        ringScale: Double,
        deltaFloor: Double
    ) -> Double {
        let ringR = max(radius * ringScale, 6.0)
        var ringSum = 0.0
        var ringN = 0
        let steps = 16
        for i in 0..<steps {
            let a = Double(i) * (2 * Double.pi / Double(steps))
            let x = Int((cx + cos(a) * ringR).rounded())
            let y = Int((cy + sin(a) * ringR).rounded())
            guard x >= 0, y >= 0, x < image.width, y < image.height else { continue }
            ringSum += Double(image.luma[y * image.width + x])
            ringN += 1
        }
        guard ringN >= 8 else { return 0 }
        let ringMean = ringSum / Double(ringN)
        let delta = blobLuma - ringMean
        return min(1, max(0, (delta - deltaFloor) / 90))
    }
}

/// RGB 광선 ∩ (LiDAR 고리로 잡은 지면 + 공 반지름).
public enum GolfBallWorldLocalizer {
    public static func localize(
        imageX: Double,
        imageY: Double,
        imageWidth: Int,
        imageHeight: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        rgbIntrinsics: simd_float3x3,
        cameraToWorld: simd_float4x4,
        groundYSamples: [Double],
        fallbackGroundY: Double,
        expectedWorldX: Double? = nil,
        expectedWorldZ: Double? = nil,
        maxOffsetMeters: Double = GolfBallVisualLock.maxOffsetFromARBallMeters
    ) -> GolfBallWorldContact? {
        guard imageWidth > 0, imageHeight > 0, sourceWidth > 0, sourceHeight > 0 else { return nil }
        let srcX = imageX * Double(sourceWidth) / Double(imageWidth)
        let srcY = imageY * Double(sourceHeight) / Double(imageHeight)
        let fx = Double(rgbIntrinsics[0, 0])
        let fy = Double(rgbIntrinsics[1, 1])
        let cx = Double(rgbIntrinsics[2, 0])
        let cy = Double(rgbIntrinsics[2, 1])
        guard fx > 1, fy > 1 else { return nil }

        let camX = (srcX - cx) / fx
        let camY = -((srcY - cy) / fy)
        let local = SIMD3<Float>(Float(camX), Float(camY), -1)
        let localLen = simd_length(local)
        guard localLen > 1e-5 else { return nil }
        let dirLocal = local / localLen
        let dir4 = cameraToWorld * SIMD4<Float>(dirLocal.x, dirLocal.y, dirLocal.z, 0)
        let dir = SIMD3<Double>(Double(dir4.x), Double(dir4.y), Double(dir4.z))
        let dirLen = (dir.x * dir.x + dir.y * dir.y + dir.z * dir.z).squareRoot()
        guard dirLen > 1e-5 else { return nil }
        let dx = dir.x / dirLen
        let dy = dir.y / dirLen
        let dz = dir.z / dirLen
        // 지면과 거의 평행하면 공 높이를 못 박는다.
        guard abs(dy) > 0.06 else { return nil }

        let origin = SIMD3<Double>(
            Double(cameraToWorld.columns.3.x),
            Double(cameraToWorld.columns.3.y),
            Double(cameraToWorld.columns.3.z)
        )
        let planeY = median(groundYSamples) ?? fallbackGroundY
        let sphereY = planeY + GolfBallVisualLock.radiusMeters
        let t = (sphereY - origin.y) / dy
        guard t.isFinite, t > 0.35, t < 3.8 else { return nil }

        let contactX = origin.x + dx * t
        let contactZ = origin.z + dz * t
        if let expectedWorldX, let expectedWorldZ {
            let offset = hypot(contactX - expectedWorldX, contactZ - expectedWorldZ)
            guard offset <= maxOffsetMeters else { return nil }
        } else {
            let fromCam = hypot(contactX - origin.x, contactZ - origin.z)
            guard fromCam <= 3.8 else { return nil }
        }

        let sampleSupport = min(1, Double(groundYSamples.count) / 8)
        let confidence = 0.55 + 0.45 * sampleSupport
        return GolfBallWorldContact(
            worldX: contactX,
            worldY: planeY,
            worldZ: contactZ,
            confidence: confidence
        )
    }

    /// 공 주변 고리(너무 가까운 픽셀=공/너무 먼 픽셀=발)에서 지면 Y.
    public static func filterGroundRingY(
        samples: [(worldX: Double, worldY: Double, worldZ: Double)],
        expectedX: Double,
        expectedY: Double,
        expectedZ: Double
    ) -> [Double] {
        var ys: [Double] = []
        ys.reserveCapacity(samples.count)
        for sample in samples {
            let xz = hypot(sample.worldX - expectedX, sample.worldZ - expectedZ)
            guard xz >= 0.07, xz <= 0.34 else { continue }
            guard abs(sample.worldY - expectedY) <= 0.12 else { continue }
            ys.append(sample.worldY)
        }
        return ys
    }

    public static func expectedRadiusPixels(
        focalX: Double,
        distanceMeters: Double
    ) -> Double {
        guard distanceMeters > 0.2 else { return 8 }
        return focalX * GolfBallVisualLock.radiusMeters / distanceMeters
    }

    /// 이미지 반지름과 그 픽셀의 깊이로 본 지름(m). 골프공 ~42.7mm.
    public static func apparentDiameterMeters(
        radiusSourcePixels: Double,
        depthMeters: Double,
        focalX: Double
    ) -> Double? {
        guard radiusSourcePixels > 0.5, depthMeters > 0.15, focalX > 1 else { return nil }
        return 2 * radiusSourcePixels * depthMeters / focalX
    }

    public static func isPlausibleGolfBallDiameter(_ meters: Double) -> Bool {
        meters >= 0.018 && meters <= 0.11
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) * 0.5
        }
        return sorted[mid]
    }
}

/// 연속 프레임 합의. 퍼터에 가려져 빠져도 잠금을 풀지 않는다.
public struct GolfBallLockConsensus: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var z: Double
        public init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    public var recent: [Sample] = []
    public var lastAppliedX: Double?
    public var lastAppliedZ: Double?
    public var locked = false
    public var alignedWithoutMove = false

    public static let window = 5
    public static let minAgree = 3
    public static let clusterMeters = 0.028

    public init() {}

    public mutating func reset() {
        recent = []
        lastAppliedX = nil
        lastAppliedZ = nil
        locked = false
        alignedWithoutMove = false
    }

    public mutating func noteMiss() {
        if recent.count > 2 {
            recent.removeFirst()
        }
    }

    public mutating func ingest(
        contact: GolfBallWorldContact,
        currentBallX: Double?,
        currentBallZ: Double?,
        physicsBallX: Double?,
        physicsBallZ: Double?,
        minAgree: Int = Self.minAgree
    ) -> GolfBallLockAction {
        if let physicsBallX, let physicsBallZ {
            let fromPhysics = hypot(contact.worldX - physicsBallX, contact.worldZ - physicsBallZ)
            guard fromPhysics <= GolfBallVisualLock.maxOffsetFromPhysicsMeters else {
                return .none
            }
        }
        if let currentBallX, let currentBallZ {
            let fromAR = hypot(contact.worldX - currentBallX, contact.worldZ - currentBallZ)
            guard fromAR <= GolfBallVisualLock.maxOffsetFromARBallMeters else {
                return .none
            }
        }

        recent.append(Sample(x: contact.worldX, y: contact.worldY, z: contact.worldZ))
        if recent.count > Self.window {
            recent.removeFirst()
        }
        guard let cluster = largestCluster(minAgree: max(1, minAgree)) else { return .none }

        let applyContact = GolfBallWorldContact(
            worldX: cluster.x,
            worldY: cluster.y,
            worldZ: cluster.z,
            confidence: contact.confidence
        )
        if !locked {
            if let currentBallX, let currentBallZ {
                let clusterFromAR = hypot(cluster.x - currentBallX, cluster.z - currentBallZ)
                if clusterFromAR <= GolfBallVisualLock.alignSlopMeters {
                    locked = true
                    alignedWithoutMove = true
                    lastAppliedX = currentBallX
                    lastAppliedZ = currentBallZ
                    return .confirmAligned
                }
            }
            locked = true
            alignedWithoutMove = false
            lastAppliedX = cluster.x
            lastAppliedZ = cluster.z
            return .apply(applyContact)
        }

        if let lastX = lastAppliedX, let lastZ = lastAppliedZ {
            let fromLock = hypot(cluster.x - lastX, cluster.z - lastZ)
            if fromLock < GolfBallVisualLock.relockDeadzoneMeters {
                return .none
            }
        }
        lastAppliedX = cluster.x
        lastAppliedZ = cluster.z
        alignedWithoutMove = false
        return .apply(applyContact)
    }

    private func largestCluster(minAgree: Int) -> (x: Double, y: Double, z: Double, count: Int)? {
        guard recent.count >= minAgree else { return nil }
        var bestCount = 0
        var bestSumX = 0.0
        var bestSumY = 0.0
        var bestSumZ = 0.0
        for i in recent.indices {
            var count = 0
            var sx = 0.0
            var sy = 0.0
            var sz = 0.0
            let a = recent[i]
            for b in recent {
                if hypot(a.x - b.x, a.z - b.z) <= Self.clusterMeters {
                    count += 1
                    sx += b.x
                    sy += b.y
                    sz += b.z
                }
            }
            if count > bestCount {
                bestCount = count
                bestSumX = sx
                bestSumY = sy
                bestSumZ = sz
            }
        }
        guard bestCount >= minAgree else { return nil }
        return (
            bestSumX / Double(bestCount),
            bestSumY / Double(bestCount),
            bestSumZ / Double(bestCount),
            bestCount
        )
    }
}
