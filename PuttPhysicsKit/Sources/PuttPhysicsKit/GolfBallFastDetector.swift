import Foundation

/// 십자선 주변 소형 ROI에서 디스크-고리 대비로 공을 찾는다.
/// CC 라벨링보다 작은 창(≤280px)에서 빠르고, 크기 사전(depth→반지름)과 궁합이 좋다.
public enum GolfBallFastDetector {
    public static let minScore = 0.48

    public static func detect(
        image: GolfBallImageBuffer,
        hint: GolfBallDetectionHint
    ) -> GolfBallBlob? {
        let width = image.width
        let height = image.height
        guard width >= 24, height >= 24,
              image.luma.count >= width * height,
              image.saturation.count >= width * height
        else { return nil }

        let searchR = min(hint.searchRadiusPixels, Double(min(width, height)) * 0.46)
        let x0 = max(0, Int(floor(hint.expectedCenterX - searchR)))
        let x1 = min(width - 1, Int(ceil(hint.expectedCenterX + searchR)))
        let y0 = max(0, Int(floor(hint.expectedCenterY - searchR)))
        let y1 = min(height - 1, Int(ceil(hint.expectedCenterY + searchR)))
        guard x1 - x0 >= 16, y1 - y0 >= 16 else { return nil }

        let roiW = x1 - x0 + 1
        let integral = IntegralGrid.build(luma: image.luma, width: width, x0: x0, y0: y0, x1: x1, y1: y1)

        let expectedR = max(3.5, hint.expectedRadiusPixels)
        let radii = [
            expectedR * 0.78,
            expectedR,
            expectedR * 1.22
        ]
        let step = expectedR >= 14 ? 2 : 1

        var bestScore = 0.0
        var bestCX = 0.0
        var bestCY = 0.0
        var bestR = expectedR

        var cy = y0
        while cy <= y1 {
            var cx = x0
            while cx <= x1 {
                let dist = hypot(Double(cx) - hint.expectedCenterX, Double(cy) - hint.expectedCenterY)
                if dist <= searchR {
                    for r in radii {
                        guard let scored = scoreDisk(
                            cx: cx,
                            cy: cy,
                            radius: r,
                            x0: x0,
                            y0: y0,
                            roiW: roiW,
                            width: width,
                            image: image,
                            integral: integral,
                            hint: hint
                        ) else { continue }
                        if scored > bestScore {
                            bestScore = scored
                            bestCX = Double(cx)
                            bestCY = Double(cy)
                            bestR = r
                        }
                    }
                }
                cx += step
            }
            cy += step
        }

        guard bestScore >= minScore else { return nil }
        let refined = refineCenter(
            image: image,
            cx: bestCX,
            cy: bestCY,
            radius: bestR,
            x0: x0,
            y0: y0,
            x1: x1,
            y1: y1
        )
        let pixelCount = max(12, Int(Double.pi * refined.radius * refined.radius * 0.55))
        return GolfBallBlob(
            centerX: refined.cx,
            centerY: refined.cy,
            radiusPixels: refined.radius,
            score: min(1, bestScore),
            pixelCount: pixelCount
        )
    }

    private struct IntegralGrid {
        var sums: [Int]
        var width: Int
        var height: Int

        static func build(luma: [UInt8], width: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> IntegralGrid {
            let roiW = x1 - x0 + 1
            let roiH = y1 - y0 + 1
            var sums = [Int](repeating: 0, count: (roiW + 1) * (roiH + 1))
            for y in 0..<roiH {
                var rowSum = 0
                let srcY = y0 + y
                let srcRow = srcY * width
                let intRow = (y + 1) * (roiW + 1)
                let prevRow = y * (roiW + 1)
                for x in 0..<roiW {
                    rowSum += Int(luma[srcRow + x0 + x])
                    let idx = intRow + x + 1
                    sums[idx] = sums[prevRow + x + 1] + rowSum
                }
            }
            return IntegralGrid(sums: sums, width: roiW + 1, height: roiH + 1)
        }

        func rectSum(x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
            let a = y0 * width + x0
            let b = y0 * width + x1
            let c = y1 * width + x0
            let d = y1 * width + x1
            return sums[d] - sums[b] - sums[c] + sums[a]
        }
    }

    private static func scoreDisk(
        cx: Int,
        cy: Int,
        radius: Double,
        x0: Int,
        y0: Int,
        roiW: Int,
        width: Int,
        image: GolfBallImageBuffer,
        integral: IntegralGrid,
        hint: GolfBallDetectionHint
    ) -> Double? {
        let minR = hint.minRadiusPixels > 0 ? hint.minRadiusPixels : radius * 0.55
        let maxR = hint.maxRadiusPixels > 0 ? hint.maxRadiusPixels : radius * 2.2
        guard radius >= minR, radius <= maxR else { return nil }

        let rInner = max(1.5, radius * 0.72)
        let rOuter = radius * 1.05
        let rRingLo = radius * 1.35
        let rRingHi = radius * 2.15

        let disk = annulusPixelStats(
            cx: cx, cy: cy, inner: 0, outer: rOuter,
            x0: x0, y0: y0, roiW: roiW, width: width, image: image, integral: integral
        )
        let core = annulusPixelStats(
            cx: cx, cy: cy, inner: 0, outer: rInner,
            x0: x0, y0: y0, roiW: roiW, width: width, image: image, integral: integral
        )
        let ring = annulusPixelStats(
            cx: cx, cy: cy, inner: rRingLo, outer: rRingHi,
            x0: x0, y0: y0, roiW: roiW, width: width, image: image, integral: integral
        )
        guard disk.count >= 8, ring.count >= 10, core.count >= 4 else { return nil }

        let diskMean = disk.lumaSum / Double(disk.count)
        let ringMean = ring.lumaSum / Double(ring.count)
        let satMean = disk.satSum / Double(disk.count)
        guard diskMean >= 128, satMean <= 105 else { return nil }

        let contrast = (diskMean - ringMean) / 90
        guard contrast >= 0.18 else { return nil }

        let sizeFit: Double = {
            let ratio = radius / max(hint.expectedRadiusPixels, 3.5)
            if ratio < 0.45 || ratio > 2.4 { return 0 }
            return 1 - min(1, abs(log(ratio)) / 1.25)
        }()
        guard sizeFit > 0.12 else { return nil }

        let dist = hypot(Double(cx) - hint.expectedCenterX, Double(cy) - hint.expectedCenterY)
        let proximity = 1 - min(1, dist / max(hint.searchRadiusPixels, 6))
        let satPenalty = min(0.35, max(0, (satMean - 55) / 140))

        return 0.42 * min(1, contrast)
            + 0.28 * sizeFit
            + 0.22 * proximity
            + 0.08 * min(1, (diskMean - 120) / 90)
            - satPenalty
    }

    private struct PixelStats {
        var count: Int
        var lumaSum: Double
        var satSum: Double
    }

    private static func annulusPixelStats(
        cx: Int,
        cy: Int,
        inner: Double,
        outer: Double,
        x0: Int,
        y0: Int,
        roiW: Int,
        width: Int,
        image: GolfBallImageBuffer,
        integral: IntegralGrid
    ) -> PixelStats {
        let ix0 = max(x0, Int(floor(Double(cx) - outer)))
        let ix1 = min(x0 + roiW - 1, Int(ceil(Double(cx) + outer)))
        let iy0 = max(y0, Int(floor(Double(cy) - outer)))
        let iy1 = min(y0 + (integral.height - 2), Int(ceil(Double(cy) + outer)))
        var count = 0
        var lumaSum = 0.0
        var satSum = 0.0
        let inner2 = inner * inner
        let outer2 = outer * outer
        for y in iy0...iy1 {
            let row = y * width
            for x in ix0...ix1 {
                let dx = Double(x - cx)
                let dy = Double(y - cy)
                let d2 = dx * dx + dy * dy
                guard d2 <= outer2, d2 >= inner2 else { continue }
                let i = row + x
                count += 1
                lumaSum += Double(image.luma[i])
                satSum += Double(image.saturation[i])
            }
        }
        return PixelStats(count: count, lumaSum: lumaSum, satSum: satSum)
    }

    private static func refineCenter(
        image: GolfBallImageBuffer,
        cx: Double,
        cy: Double,
        radius: Double,
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int
    ) -> (cx: Double, cy: Double, radius: Double) {
        var sumX = 0.0
        var sumY = 0.0
        var sumW = 0.0
        let r2 = (radius * 1.05) * (radius * 1.05)
        for y in max(y0, Int(cy - radius - 2))...min(y1, Int(cy + radius + 2)) {
            let row = y * image.width
            for x in max(x0, Int(cx - radius - 2))...min(x1, Int(cx + radius + 2)) {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                guard dx * dx + dy * dy <= r2 else { continue }
                let luma = Double(image.luma[row + x])
                let w = max(0, luma - 110)
                sumX += Double(x) * w
                sumY += Double(y) * w
                sumW += w
            }
        }
        guard sumW > 1 else { return (cx, cy, radius) }
        return (sumX / sumW, sumY / sumW, radius)
    }
}
