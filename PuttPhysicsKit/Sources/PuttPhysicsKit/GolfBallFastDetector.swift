import Foundation

/// 십자선·실볼 앵커 주변 소형 ROI에서 디스크-고리 대비로 공을 찾는다.
/// Step1(aroundReticle)과 OSD 실볼 탐색(aroundWorldAnchor)이 동일 경로.
/// coarse→fine + 적분영상 루마로 조밀 전수 탐색 비용을 줄인다.
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
        let coarseStep = max(3, min(6, Int((expectedR * 0.28).rounded())))
        let fineHalf = max(6, min(12, Int((expectedR * 0.40).rounded())))
        let fineRadii = [
            expectedR * 0.78,
            expectedR,
            expectedR * 1.22
        ]

        // 1) coarse: 큰 step + 단일 반지름 + 적분 루마(박스) + 성긴 색 샘플
        var bestScore = 0.0
        var bestCX = Int(hint.expectedCenterX.rounded())
        var bestCY = Int(hint.expectedCenterY.rounded())
        var bestR = expectedR
        var foundCoarse = false

        var cy = y0
        while cy <= y1 {
            var cx = x0
            while cx <= x1 {
                let dist = hypot(Double(cx) - hint.expectedCenterX, Double(cy) - hint.expectedCenterY)
                if dist <= searchR {
                    if let scored = scoreDisk(
                        cx: cx,
                        cy: cy,
                        radius: expectedR,
                        x0: x0,
                        y0: y0,
                        roiW: roiW,
                        width: width,
                        image: image,
                        integral: integral,
                        hint: hint,
                        sampleStride: 3,
                        useCircularColor: false
                    ), scored > bestScore {
                        bestScore = scored
                        bestCX = cx
                        bestCY = cy
                        bestR = expectedR
                        foundCoarse = true
                    }
                }
                cx += coarseStep
            }
            cy += coarseStep
        }

        // coarse가 완전 실패해도 힌트 근처 fine은 한 번 시도(작은 창·드리프트).
        let seedCX = foundCoarse ? bestCX : Int(hint.expectedCenterX.rounded())
        let seedCY = foundCoarse ? bestCY : Int(hint.expectedCenterY.rounded())
        let fineFloor = foundCoarse ? minScore * 0.72 : minScore * 0.85

        // 2) fine: seed 주변 step1 + 3 반지름 + 원형 색 샘플
        bestScore = 0
        foundCoarse = false
        let fy0 = max(y0, seedCY - fineHalf)
        let fy1 = min(y1, seedCY + fineHalf)
        let fx0 = max(x0, seedCX - fineHalf)
        let fx1 = min(x1, seedCX + fineHalf)
        for cy in fy0...fy1 {
            for cx in fx0...fx1 {
                let dist = hypot(Double(cx) - hint.expectedCenterX, Double(cy) - hint.expectedCenterY)
                guard dist <= searchR else { continue }
                for r in fineRadii {
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
                        hint: hint,
                        sampleStride: 2,
                        useCircularColor: true
                    ) else { continue }
                    if scored > bestScore {
                        bestScore = scored
                        bestCX = cx
                        bestCY = cy
                        bestR = r
                        foundCoarse = true
                    }
                }
            }
        }

        guard foundCoarse, bestScore >= max(minScore, fineFloor * 0.9) else { return nil }
        guard bestScore >= minScore else { return nil }

        let refined = refineCenter(
            image: image,
            cx: Double(bestCX),
            cy: Double(bestCY),
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
        /// ROI 원점(이미지 좌표).
        var originX: Int
        var originY: Int
        var width: Int
        var height: Int
        var roiW: Int
        var roiH: Int

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
            return IntegralGrid(
                sums: sums,
                originX: x0,
                originY: y0,
                width: roiW + 1,
                height: roiH + 1,
                roiW: roiW,
                roiH: roiH
            )
        }

        /// inclusive image-space rect → sum/count. O(1).
        func rectStats(ix0: Int, iy0: Int, ix1: Int, iy1: Int) -> (sum: Int, count: Int)? {
            let lx0 = max(0, ix0 - originX)
            let ly0 = max(0, iy0 - originY)
            let lx1 = min(roiW - 1, ix1 - originX)
            let ly1 = min(roiH - 1, iy1 - originY)
            guard lx1 >= lx0, ly1 >= ly0 else { return nil }
            let a = ly0 * width + lx0
            let b = ly0 * width + (lx1 + 1)
            let c = (ly1 + 1) * width + lx0
            let d = (ly1 + 1) * width + (lx1 + 1)
            let sum = sums[d] - sums[b] - sums[c] + sums[a]
            let count = (lx1 - lx0 + 1) * (ly1 - ly0 + 1)
            return (sum, count)
        }

        /// 원 근사 박스 디스크/링 루마. outer·inner는 반지름(px).
        func diskRingLuma(cx: Int, cy: Int, diskR: Double, ringLo: Double, ringHi: Double) -> (diskMean: Double, ringMean: Double, diskCount: Int, ringCount: Int)? {
            let dHalf = max(1, Int(diskR.rounded()))
            guard let disk = rectStats(ix0: cx - dHalf, iy0: cy - dHalf, ix1: cx + dHalf, iy1: cy + dHalf),
                  disk.count >= 8
            else { return nil }

            let hi = max(dHalf + 1, Int(ringHi.rounded()))
            let lo = max(0, Int(ringLo.rounded()))
            guard let outer = rectStats(ix0: cx - hi, iy0: cy - hi, ix1: cx + hi, iy1: cy + hi) else {
                return nil
            }
            let inner: (sum: Int, count: Int)
            if lo <= 0 {
                inner = (0, 0)
            } else if let stats = rectStats(ix0: cx - lo, iy0: cy - lo, ix1: cx + lo, iy1: cy + lo) {
                inner = stats
            } else {
                inner = (0, 0)
            }
            let ringSum = outer.sum - inner.sum
            let ringCount = outer.count - inner.count
            guard ringCount >= 10 else { return nil }
            return (
                Double(disk.sum) / Double(disk.count),
                Double(ringSum) / Double(ringCount),
                disk.count,
                ringCount
            )
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
        hint: GolfBallDetectionHint,
        sampleStride: Int,
        useCircularColor: Bool
    ) -> Double? {
        let minR = hint.minRadiusPixels > 0 ? hint.minRadiusPixels : radius * 0.55
        let maxR = hint.maxRadiusPixels > 0 ? hint.maxRadiusPixels : radius * 2.2
        guard radius >= minR, radius <= maxR else { return nil }

        let rOuter = radius * 1.05
        let rRingLo = radius * 1.35
        let rRingHi = radius * 2.15

        guard let luma = integral.diskRingLuma(
            cx: cx,
            cy: cy,
            diskR: rOuter,
            ringLo: rRingLo,
            ringHi: rRingHi
        ) else { return nil }

        let diskMean = luma.diskMean
        let ringMean = luma.ringMean

        let color = sampleDiskColor(
            cx: cx,
            cy: cy,
            radius: rOuter,
            x0: x0,
            y0: y0,
            roiW: roiW,
            width: width,
            image: image,
            stride: max(1, sampleStride),
            circular: useCircularColor
        )
        guard color.count >= 4 else { return nil }
        let satMean = color.satSum / Double(color.count)
        let meanHue = GolfBallColorPalette.hueByte(
            fromDegrees: atan2(color.hueSin / Double(color.count), color.hueCos / Double(color.count)) * 180 / .pi
        )
        let matched = GolfBallColorPalette.matches(
            luma: Int(diskMean.rounded()),
            saturation: Int(satMean.rounded()),
            hueByte: meanHue
        )
        let whiteFallback = matched == nil && diskMean >= 128 && satMean <= 105
        guard matched != nil || whiteFallback else { return nil }

        let absolute = GolfBallColorPalette.prefersAbsoluteRingContrast(color: matched) || matched == .black
        let rawContrast = absolute ? abs(diskMean - ringMean) : (diskMean - ringMean)
        let contrast = (rawContrast - (absolute ? 10.0 : 0.0)) / 90
        guard contrast >= (matched == nil || matched == .white ? 0.18 : 0.08) else { return nil }

        let sizeFit: Double = {
            let ratio = radius / max(hint.expectedRadiusPixels, 3.5)
            if ratio < 0.55 || ratio > 2.40 { return 0 }
            return 1 - min(1, abs(log(ratio)) / 0.85)
        }()
        guard sizeFit > 0.18 else { return nil }

        let dist = hypot(Double(cx) - hint.expectedCenterX, Double(cy) - hint.expectedCenterY)
        let proximity = 1 - min(1, dist / max(hint.searchRadiusPixels, 6))
        let satPenalty = matched == nil || matched == .white
            ? min(0.35, max(0, (satMean - 55) / 140))
            : 0

        let brightnessTerm: Double = {
            if matched == .black { return min(1, (80 - diskMean) / 60) }
            return min(1, (diskMean - 80) / 120)
        }()

        return 0.42 * min(1, contrast)
            + 0.28 * sizeFit
            + 0.22 * proximity
            + 0.08 * max(0, brightnessTerm)
            - satPenalty
    }

    private struct ColorSample {
        var count: Int
        var satSum: Double
        var hueSin: Double
        var hueCos: Double
    }

    private static func sampleDiskColor(
        cx: Int,
        cy: Int,
        radius: Double,
        x0: Int,
        y0: Int,
        roiW: Int,
        width: Int,
        image: GolfBallImageBuffer,
        stride: Int,
        circular: Bool
    ) -> ColorSample {
        let half = max(1, Int(radius.rounded()))
        let xMin = max(0, max(x0, cx - half))
        let xMax = min(image.width - 1, min(x0 + roiW - 1, cx + half))
        let yMin = max(0, max(y0, cy - half))
        let yMax = min(image.height - 1, cy + half)
        var count = 0
        var satSum = 0.0
        var hueSin = 0.0
        var hueCos = 0.0
        let r2 = radius * radius
        var y = yMin
        while y <= yMax {
            let row = y * width
            var x = xMin
            while x <= xMax {
                let inside: Bool
                if circular {
                    let dx = Double(x - cx)
                    let dy = Double(y - cy)
                    inside = dx * dx + dy * dy <= r2
                } else {
                    inside = true
                }
                if inside {
                    let i = row + x
                    count += 1
                    satSum += Double(image.saturation[i])
                    let hueDeg = Double(Int(image.hueByte(at: i)) * 2) * .pi / 180
                    hueSin += sin(hueDeg)
                    hueCos += cos(hueDeg)
                }
                x += stride
            }
            y += stride
        }
        return ColorSample(count: count, satSum: satSum, hueSin: hueSin, hueCos: hueCos)
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
                let i = row + x
                let luma = Double(image.luma[i])
                let sat = Double(image.saturation[i])
                let hue = image.hueByte(at: i)
                let matched = GolfBallColorPalette.matches(
                    luma: Int(luma),
                    saturation: Int(sat),
                    hueByte: hue
                )
                let w: Double
                if matched == .black {
                    w = max(0, 70 - luma)
                } else if matched != nil, matched != .white {
                    w = max(0, sat)
                } else {
                    w = max(0, luma - 110)
                }
                sumX += Double(x) * w
                sumY += Double(y) * w
                sumW += w
            }
        }
        guard sumW > 1 else { return (cx, cy, radius) }
        return (sumX / sumW, sumY / sumW, radius)
    }
}
