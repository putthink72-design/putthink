import Foundation

// MARK: - Gate 6 types (RGB+깊이 융합 — 순수 검증 코어)

/// 자동 인식 대상. 실제 스캔 앵커와 무관한 섀도 관측용.
public enum Gate6TargetKind: String, Sendable, Codable, CaseIterable {
    case ball
    case hole
}

/// RGB 단계에서 뽑힌 이미지 공간 후보 (정규화 좌표 0…1).
public struct Gate6ImageCandidate: Sendable, Equatable, Codable {
    public var kind: Gate6TargetKind
    public var normalizedX: Double
    public var normalizedY: Double
    /// 대략적 반경 (이미지 짧은 변 대비 정규화).
    public var radiusNorm: Double
    /// RGB 점수 0…1 (높을수록 유력).
    public var score: Double

    public init(
        kind: Gate6TargetKind,
        normalizedX: Double,
        normalizedY: Double,
        radiusNorm: Double,
        score: Double
    ) {
        self.kind = kind
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.radiusNorm = radiusNorm
        self.score = score
    }
}

public enum Gate6DepthVerdict: String, Sendable, Codable, Equatable {
    case accepted
    /// 주변과 단차가 거의 없음 (그림자·페인트 등 평탄 오탐).
    case rejectedFlat
    /// 볼인데 함몰 / 홀인데 돌출 등 부호 불일치.
    case rejectedWrongSign
    /// 단차는 있으나 골프공·홀컵 스케일과 불일치.
    case rejectedScale
    case insufficientData
}

public struct Gate6DepthCrossCheckResult: Sendable, Equatable, Codable {
    public var verdict: Gate6DepthVerdict
    public var centerDepthMeters: Double?
    public var ringDepthMeters: Double?
    /// center − ring. ARKit depth(카메라 거리)에서 음수 ≈ 돌출(더 가까움).
    public var deltaMeters: Double?

    public init(
        verdict: Gate6DepthVerdict,
        centerDepthMeters: Double? = nil,
        ringDepthMeters: Double? = nil,
        deltaMeters: Double? = nil
    ) {
        self.verdict = verdict
        self.centerDepthMeters = centerDepthMeters
        self.ringDepthMeters = ringDepthMeters
        self.deltaMeters = deltaMeters
    }

    public var accepted: Bool { verdict == .accepted }
}

/// 한 프레임의 최종 섀도 관측 (월드좌표는 앱에서 채움, 코어는 깊이 판정까지).
public struct Gate6DetectionResult: Sendable, Equatable, Codable {
    public var kind: Gate6TargetKind
    public var candidate: Gate6ImageCandidate
    public var depth: Gate6DepthCrossCheckResult
    public var worldX: Double?
    public var worldY: Double?
    public var worldZ: Double?

    public init(
        kind: Gate6TargetKind,
        candidate: Gate6ImageCandidate,
        depth: Gate6DepthCrossCheckResult,
        worldX: Double? = nil,
        worldY: Double? = nil,
        worldZ: Double? = nil
    ) {
        self.kind = kind
        self.candidate = candidate
        self.depth = depth
        self.worldX = worldX
        self.worldY = worldY
        self.worldZ = worldZ
    }
}

/// 행 우선 depth 격자 (미터, 카메라까지의 거리 — 작을수록 가까움).
public struct Gate6DepthMap: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var meters: [Float]

    public init(width: Int, height: Int, meters: [Float]) {
        precondition(width > 0 && height > 0)
        precondition(meters.count == width * height)
        self.width = width
        self.height = height
        self.meters = meters
    }

    public func sample(normalizedX: Double, normalizedY: Double) -> Float? {
        let x = Int((normalizedX * Double(width - 1)).rounded())
        let y = Int((normalizedY * Double(height - 1)).rounded())
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let value = meters[y * width + x]
        guard value.isFinite, value > 0.05, value < 20 else { return nil }
        return value
    }
}

public enum Gate6Detection {
    /// 볼: LiDAR는 골프공 돌출을 작게 잡으므로 문턱을 낮춤 (수 mm).
    public static let ballMinProtrusionMeters = 0.003
    public static let ballMaxProtrusionMeters = 0.070
    /// 홀: 중심이 주변보다 멀고(함몰) 홀컵 스케일.
    public static let holeMinDepressionMeters = 0.012
    public static let holeMaxDepressionMeters = 0.12

    /// RGB 점수가 높고 깊이 단차가 약한 돌출일 때 허용하는 최소 돌출.
    public static let ballSoftProtrusionMeters = 0.0015
    public static let ballSoftRGBScore = 0.45

    /// 깊이맵으로 RGB 후보를 교차검증한다.
    public static func crossCheckDepth(
        kind: Gate6TargetKind,
        depth: Gate6DepthMap,
        candidate: Gate6ImageCandidate,
        innerRadiusNorm: Double? = nil,
        ringInnerNorm: Double? = nil,
        ringOuterNorm: Double? = nil
    ) -> Gate6DepthCrossCheckResult {
        let r = max(candidate.radiusNorm, 0.004)
        let innerR = innerRadiusNorm ?? max(r * 0.45, 0.003)
        let ringIn = ringInnerNorm ?? max(r * 1.2, innerR * 1.5)
        let ringOut = ringOuterNorm ?? max(r * 2.4, ringIn * 1.4)

        guard let center = medianDepth(
            depth: depth,
            cx: candidate.normalizedX,
            cy: candidate.normalizedY,
            radiusNorm: innerR,
            sampleCount: 12
        ) else {
            return Gate6DepthCrossCheckResult(verdict: .insufficientData)
        }
        guard let ring = medianDepthRing(
            depth: depth,
            cx: candidate.normalizedX,
            cy: candidate.normalizedY,
            innerNorm: ringIn,
            outerNorm: ringOut,
            sampleCount: 24
        ) else {
            return Gate6DepthCrossCheckResult(verdict: .insufficientData)
        }

        let delta = Double(center - ring)
        switch kind {
        case .ball:
            // 돌출: center < ring → delta 음수. 부호 불일치를 평탄보다 먼저 판정.
            if delta > 0 {
                return Gate6DepthCrossCheckResult(
                    verdict: .rejectedWrongSign,
                    centerDepthMeters: Double(center),
                    ringDepthMeters: Double(ring),
                    deltaMeters: delta
                )
            }
            let protrusion = -delta
            if protrusion < ballMinProtrusionMeters * 0.25 {
                return Gate6DepthCrossCheckResult(
                    verdict: .rejectedFlat,
                    centerDepthMeters: Double(center),
                    ringDepthMeters: Double(ring),
                    deltaMeters: delta
                )
            }
            if protrusion < ballMinProtrusionMeters || protrusion > ballMaxProtrusionMeters {
                return Gate6DepthCrossCheckResult(
                    verdict: .rejectedScale,
                    centerDepthMeters: Double(center),
                    ringDepthMeters: Double(ring),
                    deltaMeters: delta
                )
            }
            return Gate6DepthCrossCheckResult(
                verdict: .accepted,
                centerDepthMeters: Double(center),
                ringDepthMeters: Double(ring),
                deltaMeters: delta
            )

        case .hole:
            // 함몰: center > ring → delta 양수
            if delta < 0 {
                return Gate6DepthCrossCheckResult(
                    verdict: .rejectedWrongSign,
                    centerDepthMeters: Double(center),
                    ringDepthMeters: Double(ring),
                    deltaMeters: delta
                )
            }
            let depression = delta
            if depression < holeMinDepressionMeters * 0.35 {
                return Gate6DepthCrossCheckResult(
                    verdict: .rejectedFlat,
                    centerDepthMeters: Double(center),
                    ringDepthMeters: Double(ring),
                    deltaMeters: delta
                )
            }
            if depression < holeMinDepressionMeters || depression > holeMaxDepressionMeters {
                return Gate6DepthCrossCheckResult(
                    verdict: .rejectedScale,
                    centerDepthMeters: Double(center),
                    ringDepthMeters: Double(ring),
                    deltaMeters: delta
                )
            }
            return Gate6DepthCrossCheckResult(
                verdict: .accepted,
                centerDepthMeters: Double(center),
                ringDepthMeters: Double(ring),
                deltaMeters: delta
            )
        }
    }

    /// RGB 후보 목록을 깊이로 걸러 최고 점수 통과 후보를 고른다.
    /// 볼은 LiDAR 해상도 한계로 단차가 약해도 RGB가 강하면 soft accept.
    public static func selectBest(
        kind: Gate6TargetKind,
        candidates: [Gate6ImageCandidate],
        depth: Gate6DepthMap
    ) -> (best: Gate6DetectionResult?, rejectedByDepth: Int, rgbCount: Int) {
        let filtered = candidates.filter { $0.kind == kind }.sorted { $0.score > $1.score }
        var rejected = 0
        var best: Gate6DetectionResult?
        var soft: Gate6DetectionResult?
        for candidate in filtered {
            let check = crossCheckDepth(kind: kind, depth: depth, candidate: candidate)
            if check.accepted {
                if best == nil || candidate.score > best!.candidate.score {
                    best = Gate6DetectionResult(kind: kind, candidate: candidate, depth: check)
                }
            } else if check.verdict != .insufficientData {
                rejected += 1
                if kind == .ball,
                   soft == nil,
                   candidate.score >= ballSoftRGBScore,
                   let delta = check.deltaMeters,
                   delta < 0,
                   -delta >= ballSoftProtrusionMeters
                {
                    soft = Gate6DetectionResult(kind: kind, candidate: candidate, depth: check)
                    // soft: verdict는 flat/scale이어도 결과에 포함 — UI는 accepted 외에 soft 표시 가능
                    // accepted 플래그를 위해 soft용으로 verdict를 accepted로 승격하지 않고
                    // 별도 경로에서 best가 없을 때만 soft를 채택하되 depth를 accepted처럼 취급
                }
            }
        }
        if best == nil, let soft {
            // 약한 돌출 + 강한 RGB → 섀도 통과로 승격 (프로덕션 앵커에는 여전히 미사용)
            let promoted = Gate6DepthCrossCheckResult(
                verdict: .accepted,
                centerDepthMeters: soft.depth.centerDepthMeters,
                ringDepthMeters: soft.depth.ringDepthMeters,
                deltaMeters: soft.depth.deltaMeters
            )
            best = Gate6DetectionResult(
                kind: soft.kind,
                candidate: soft.candidate,
                depth: promoted,
                worldX: soft.worldX,
                worldY: soft.worldY,
                worldZ: soft.worldZ
            )
        }
        return (best, rejected, filtered.count)
    }

    /// 흰 골프공용: 절대 밝기 + 다중 스케일 국소 대비 + 피크.
    public static func extractBrightBallCandidates(
        luma: [UInt8],
        width: Int,
        height: Int,
        minAbsoluteLuma: UInt8 = 150,
        minScore: Double = 0.16
    ) -> [Gate6ImageCandidate] {
        precondition(luma.count == width * height)
        var candidates: [Gate6ImageCandidate] = []
        let shortSide = min(width, height)
        let steps = [max(1, shortSide / 64), max(2, shortSide / 40), max(2, shortSide / 28)]
        for step in Set(steps) {
            for y in stride(from: step * 2, to: height - step * 2, by: step) {
                for x in stride(from: step * 2, to: width - step * 2, by: step) {
                    let idx = y * width + x
                    let center = Int(luma[idx])
                    guard center >= Int(minAbsoluteLuma) else { continue }
                    // 4-이웃보다 확실히 밝아야 피크 (나무결 잔점 억제)
                    let n = Int(luma[idx - width])
                    let s = Int(luma[idx + width])
                    let w = Int(luma[idx - 1])
                    let e = Int(luma[idx + 1])
                    guard center >= n, center >= s, center >= w, center >= e else { continue }
                    let neighborMax = max(max(n, s), max(w, e))
                    guard center - neighborMax >= 2 || center >= 210 else { continue }

                    // 근거리 링 vs 원거리 링
                    var nearSum = 0.0
                    var nearCount = 0.0
                    var farSum = 0.0
                    var farCount = 0.0
                    for dy in -step...step {
                        for dx in -step...step {
                            if dx == 0 && dy == 0 { continue }
                            nearSum += Double(luma[(y + dy) * width + (x + dx)])
                            nearCount += 1
                        }
                    }
                    let farR = step * 3
                    for dy in stride(from: -farR, through: farR, by: step) {
                        for dx in stride(from: -farR, through: farR, by: step) {
                            let ax = abs(dx)
                            let ay = abs(dy)
                            if ax <= step && ay <= step { continue }
                            let xx = x + dx
                            let yy = y + dy
                            guard xx >= 0, yy >= 0, xx < width, yy < height else { continue }
                            farSum += Double(luma[yy * width + xx])
                            farCount += 1
                        }
                    }
                    let near = nearSum / max(nearCount, 1)
                    let far = farSum / max(farCount, 1)
                    let contrastNear = Double(center) - near
                    let contrastFar = Double(center) - far
                    // 공은 주변보다 뚜렷이 밝다. 나무결(약대비)은 제외.
                    guard contrastFar >= 18 || contrastNear >= 14 else { continue }

                    let brightScore = max(0, min(1, (Double(center) - 140) / 90.0))
                    let contrastScore = max(0, min(1, max(contrastNear, contrastFar) / 50.0))
                    let score = 0.45 * brightScore + 0.55 * contrastScore
                    guard score >= minScore else { continue }

                    candidates.append(
                        Gate6ImageCandidate(
                            kind: .ball,
                            normalizedX: Double(x) / Double(max(width - 1, 1)),
                            normalizedY: Double(y) / Double(max(height - 1, 1)),
                            radiusNorm: Double(step) / Double(shortSide),
                            score: score
                        )
                    )
                }
            }
        }
        return nonMaximumSuppression(candidates, minSeparation: 0.04)
    }

    /// 합성 RGB 격자에서 밝은(볼)/어두운(홀) 블롭 후보를 추출 (단위테스트·홀·폴백용).
    public static func extractSyntheticRGBCandidates(
        kind: Gate6TargetKind,
        luma: [UInt8],
        width: Int,
        height: Int,
        minScore: Double = 0.35
    ) -> [Gate6ImageCandidate] {
        if kind == .ball {
            return extractBrightBallCandidates(
                luma: luma,
                width: width,
                height: height,
                minScore: min(minScore, 0.16)
            )
        }
        precondition(luma.count == width * height)
        var candidates: [Gate6ImageCandidate] = []
        let step = max(2, min(width, height) / 32)
        for y in stride(from: step, to: height - step, by: step) {
            for x in stride(from: step, to: width - step, by: step) {
                let center = Double(luma[y * width + x])
                var ringSum = 0.0
                var ringCount = 0.0
                for dy in [-step, 0, step] {
                    for dx in [-step, 0, step] {
                        if dx == 0 && dy == 0 { continue }
                        ringSum += Double(luma[(y + dy) * width + (x + dx)])
                        ringCount += 1
                    }
                }
                let ring = ringSum / max(ringCount, 1)
                let score = max(0, min(1, (ring - center) / 80.0))
                if score >= minScore {
                    candidates.append(
                        Gate6ImageCandidate(
                            kind: kind,
                            normalizedX: Double(x) / Double(width - 1),
                            normalizedY: Double(y) / Double(height - 1),
                            radiusNorm: Double(step) / Double(min(width, height)),
                            score: score
                        )
                    )
                }
            }
        }
        return nonMaximumSuppression(candidates, minSeparation: 0.06)
    }

    public static func nonMaximumSuppression(
        _ candidates: [Gate6ImageCandidate],
        minSeparation: Double
    ) -> [Gate6ImageCandidate] {
        let sorted = candidates.sorted { $0.score > $1.score }
        var kept: [Gate6ImageCandidate] = []
        for candidate in sorted {
            let tooClose = kept.contains {
                hypot($0.normalizedX - candidate.normalizedX, $0.normalizedY - candidate.normalizedY)
                    < minSeparation
            }
            if !tooClose {
                kept.append(candidate)
            }
        }
        return kept
    }

    // MARK: - Depth sampling

    private static func medianDepth(
        depth: Gate6DepthMap,
        cx: Double,
        cy: Double,
        radiusNorm: Double,
        sampleCount: Int
    ) -> Float? {
        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let angle = Double(i) / Double(sampleCount) * 2 * .pi
            let px = cx + cos(angle) * radiusNorm * 0.5
            let py = cy + sin(angle) * radiusNorm * 0.5
            if let value = depth.sample(normalizedX: px, normalizedY: py) {
                samples.append(value)
            }
        }
        if let center = depth.sample(normalizedX: cx, normalizedY: cy) {
            samples.append(center)
        }
        return median(samples)
    }

    private static func medianDepthRing(
        depth: Gate6DepthMap,
        cx: Double,
        cy: Double,
        innerNorm: Double,
        outerNorm: Double,
        sampleCount: Int
    ) -> Float? {
        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)
        let midR = (innerNorm + outerNorm) * 0.5
        for i in 0..<sampleCount {
            let angle = Double(i) / Double(sampleCount) * 2 * .pi
            let px = cx + cos(angle) * midR
            let py = cy + sin(angle) * midR
            if let value = depth.sample(normalizedX: px, normalizedY: py) {
                samples.append(value)
            }
        }
        return median(samples)
    }

    private static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) * 0.5
        }
        return sorted[mid]
    }
}
