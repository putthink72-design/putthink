import Foundation

/// 등고선 폴리라인 — 높이맵 로컬 (x, y) 평면 좌표와 상대고도(height).
public struct ContourPolyline: Sendable, Equatable {
    public var level: Double
    public var points: [ContourPoint]

    public init(level: Double, points: [ContourPoint]) {
        self.level = level
        self.points = points
    }
}

public struct ContourPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    /// 볼 원점 기준 상대고도(m). AR 배치 시 `transform.world(..., height:)`에 그대로 사용.
    public var height: Double

    public init(x: Double, y: Double, height: Double) {
        self.x = x
        self.y = y
        self.height = height
    }
}

public struct ContourBuildConfiguration: Sendable, Equatable {
    /// 등고 간격(m). 기본 1cm.
    public var intervalMeters: Double
    /// 생성할 최대 레벨 수(상·하 합).
    public var maxLevels: Int
    /// 볼→홀 축 기준 좌우 반폭(m). nil이면 맵 전체.
    public var corridorHalfWidth: Double?
    /// 홀까지 거리(m). corridor와 함께 y∈[-margin, hole+margin] 클립.
    public var holeDistance: Double?
    public var corridorMargin: Double
    /// 측정(또는 보간)된 셀만 사용.
    public var requireKnownCell: Bool
    /// Chaikin 코너 절삭 반복 횟수(0=원시 marching squares).
    public var smoothIterations: Int
    /// 스무딩 후 최대 세그먼트 길이(m). 이보다 길면 보간으로 쪼갬.
    public var maxSegmentLength: Double

    public init(
        intervalMeters: Double = 0.01,
        maxLevels: Int = 48,
        corridorHalfWidth: Double? = 1.2,
        holeDistance: Double? = nil,
        corridorMargin: Double = 0.4,
        requireKnownCell: Bool = true,
        smoothIterations: Int = 3,
        maxSegmentLength: Double = 0.03
    ) {
        self.intervalMeters = intervalMeters
        self.maxLevels = maxLevels
        self.corridorHalfWidth = corridorHalfWidth
        self.holeDistance = holeDistance
        self.corridorMargin = corridorMargin
        self.requireKnownCell = requireKnownCell
        self.smoothIterations = smoothIterations
        self.maxSegmentLength = maxSegmentLength
    }
}

/// 높이맵에서 등고선(동일 고도 곡선)을 marching squares로 추출한다.
public enum ContourLineBuilder {
    public static func build(
        map: HeightMap,
        configuration: ContourBuildConfiguration = ContourBuildConfiguration()
    ) -> [ContourPolyline] {
        guard map.width >= 2, map.height >= 2 else { return [] }
        guard configuration.intervalMeters > 0 else { return [] }

        let levels = contourLevels(map: map, configuration: configuration)
        guard !levels.isEmpty else { return [] }

        var result: [ContourPolyline] = []
        result.reserveCapacity(levels.count)
        for level in levels {
            let segments = extractSegments(map: map, level: level, configuration: configuration)
            let chains = chainSegments(segments)
            for chain in chains where chain.count >= 2 {
                var points = chain.map { point -> ContourPoint in
                    ContourPoint(x: point.x, y: point.y, height: level)
                }
                points = smooth(points, iterations: configuration.smoothIterations)
                points = catmullRomResample(points, samplesPerSegment: 8)
                points = densify(points, maxSegmentLength: configuration.maxSegmentLength)
                guard points.count >= 2 else { continue }
                result.append(ContourPolyline(level: level, points: points))
            }
        }
        return result
    }

    /// Chaikin corner-cutting으로 격자 각진 등고를 부드럽게 만든다.
    public static func smooth(_ points: [ContourPoint], iterations: Int) -> [ContourPoint] {
        guard points.count >= 3, iterations > 0 else { return points }
        var current = points
        for _ in 0..<iterations {
            var next: [ContourPoint] = []
            next.reserveCapacity(current.count * 2)
            next.append(current[0])
            for index in 0..<(current.count - 1) {
                let a = current[index]
                let b = current[index + 1]
                next.append(
                    ContourPoint(
                        x: 0.75 * a.x + 0.25 * b.x,
                        y: 0.75 * a.y + 0.25 * b.y,
                        height: a.height
                    )
                )
                next.append(
                    ContourPoint(
                        x: 0.25 * a.x + 0.75 * b.x,
                        y: 0.25 * a.y + 0.75 * b.y,
                        height: b.height
                    )
                )
            }
            next.append(current[current.count - 1])
            current = next
        }
        return current
    }

    /// Catmull-Rom 스플라인으로 각진 폴라인을 부드러운 곡선 샘플로 재샘플링한다.
    public static func catmullRomResample(
        _ points: [ContourPoint],
        samplesPerSegment: Int
    ) -> [ContourPoint] {
        guard points.count >= 2, samplesPerSegment > 0 else { return points }
        if points.count == 2 {
            return densify(points, maxSegmentLength: 0.02)
        }

        var result: [ContourPoint] = []
        result.reserveCapacity((points.count - 1) * samplesPerSegment + 1)
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
            for sample in 0..<samplesPerSegment {
                let t = Double(sample) / Double(samplesPerSegment)
                result.append(
                    ContourPoint(
                        x: catmullRom(p0.x, p1.x, p2.x, p3.x, t),
                        y: catmullRom(p0.y, p1.y, p2.y, p3.y, t),
                        height: p1.height
                    )
                )
            }
        }
        if let last = points.last {
            result.append(last)
        }
        return result
    }

    private static func catmullRom(
        _ p0: Double,
        _ p1: Double,
        _ p2: Double,
        _ p3: Double,
        _ t: Double
    ) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2.0 * p1)
            + (-p0 + p2) * t
            + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
            + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
        )
    }

    /// 긴 직선 구간을 짧은 세그먼트로 쪼개 AR에서 곡선처럼 보이게 한다.
    public static func densify(_ points: [ContourPoint], maxSegmentLength: Double) -> [ContourPoint] {
        guard points.count >= 2, maxSegmentLength > 0 else { return points }
        var result: [ContourPoint] = [points[0]]
        for index in 1..<points.count {
            let a = result[result.count - 1]
            let b = points[index]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length = hypot(dx, dy)
            if length <= maxSegmentLength {
                result.append(b)
                continue
            }
            let steps = Int(ceil(length / maxSegmentLength))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                result.append(
                    ContourPoint(
                        x: a.x + dx * t,
                        y: a.y + dy * t,
                        height: a.height
                    )
                )
            }
        }
        return result
    }

    // MARK: - Levels

    static func contourLevels(
        map: HeightMap,
        configuration: ContourBuildConfiguration
    ) -> [Double] {
        var minH = Double.infinity
        var maxH = -Double.infinity
        var count = 0
        for y in 0..<map.height {
            for x in 0..<map.width {
                guard isUsable(map: map, x: x, y: y, configuration: configuration) else { continue }
                let h = map.value(x: x, y: y)
                guard h.isFinite else { continue }
                minH = min(minH, h)
                maxH = max(maxH, h)
                count += 1
            }
        }
        guard count >= 4, maxH > minH else { return [] }

        let span = maxH - minH
        guard span > 1e-6 else { return [] }

        // 고정 간격이 실제 고도 범위보다 크면 등고가 0개 → 범위에 맞게 적응.
        var interval = configuration.intervalMeters
        var levelCount = Int(floor(span / interval))
        if levelCount < 6 {
            levelCount = 6
            interval = span / Double(levelCount + 1)
        }
        levelCount = min(max(levelCount, 1), configuration.maxLevels)

        var levels: [Double] = []
        levels.reserveCapacity(levelCount)
        for index in 1...levelCount {
            levels.append(minH + span * Double(index) / Double(levelCount + 1))
        }
        return levels
    }

    // MARK: - Marching squares

    private struct Segment: Equatable {
        var a: Point2
        var b: Point2
    }

    private struct Point2: Hashable {
        var x: Double
        var y: Double

        func quantized(scale: Double = 1e5) -> Point2 {
            Point2(
                x: (x * scale).rounded() / scale,
                y: (y * scale).rounded() / scale
            )
        }
    }

    private static func extractSegments(
        map: HeightMap,
        level: Double,
        configuration: ContourBuildConfiguration
    ) -> [Segment] {
        var segments: [Segment] = []
        for j in 0..<(map.height - 1) {
            for i in 0..<(map.width - 1) {
                guard
                    isUsable(map: map, x: i, y: j, configuration: configuration),
                    isUsable(map: map, x: i + 1, y: j, configuration: configuration),
                    isUsable(map: map, x: i, y: j + 1, configuration: configuration),
                    isUsable(map: map, x: i + 1, y: j + 1, configuration: configuration)
                else { continue }

                let c00 = map.worldCoordinate(x: i, y: j)
                let c10 = map.worldCoordinate(x: i + 1, y: j)
                let c01 = map.worldCoordinate(x: i, y: j + 1)
                let c11 = map.worldCoordinate(x: i + 1, y: j + 1)

                if let half = configuration.corridorHalfWidth {
                    let midX = (c00.x + c11.x) * 0.5
                    let midY = (c00.y + c11.y) * 0.5
                    if abs(midX) > half { continue }
                    if let hole = configuration.holeDistance {
                        let lo = -configuration.corridorMargin
                        let hi = hole + configuration.corridorMargin
                        if midY < lo || midY > hi { continue }
                    }
                }

                let v00 = map.value(x: i, y: j)
                let v10 = map.value(x: i + 1, y: j)
                let v01 = map.value(x: i, y: j + 1)
                let v11 = map.value(x: i + 1, y: j + 1)
                guard v00.isFinite, v10.isFinite, v01.isFinite, v11.isFinite else { continue }

                var code = 0
                if v00 >= level { code |= 1 }
                if v10 >= level { code |= 2 }
                if v11 >= level { code |= 4 }
                if v01 >= level { code |= 8 }

                let bottom = lerpEdge(c00, v00, c10, v10, level)
                let right = lerpEdge(c10, v10, c11, v11, level)
                let top = lerpEdge(c01, v01, c11, v11, level)
                let left = lerpEdge(c00, v00, c01, v01, level)

                switch code {
                case 0, 15:
                    break
                case 1, 14:
                    if let a = left, let b = bottom { segments.append(Segment(a: a, b: b)) }
                case 2, 13:
                    if let a = bottom, let b = right { segments.append(Segment(a: a, b: b)) }
                case 3, 12:
                    if let a = left, let b = right { segments.append(Segment(a: a, b: b)) }
                case 4, 11:
                    if let a = right, let b = top { segments.append(Segment(a: a, b: b)) }
                case 5:
                    // saddle — split by average
                    let avg = (v00 + v10 + v01 + v11) * 0.25
                    if avg >= level {
                        if let a = left, let b = top { segments.append(Segment(a: a, b: b)) }
                        if let a = bottom, let b = right { segments.append(Segment(a: a, b: b)) }
                    } else {
                        if let a = left, let b = bottom { segments.append(Segment(a: a, b: b)) }
                        if let a = top, let b = right { segments.append(Segment(a: a, b: b)) }
                    }
                case 6, 9:
                    if let a = bottom, let b = top { segments.append(Segment(a: a, b: b)) }
                case 7, 8:
                    if let a = left, let b = top { segments.append(Segment(a: a, b: b)) }
                case 10:
                    let avg = (v00 + v10 + v01 + v11) * 0.25
                    if avg >= level {
                        if let a = left, let b = bottom { segments.append(Segment(a: a, b: b)) }
                        if let a = top, let b = right { segments.append(Segment(a: a, b: b)) }
                    } else {
                        if let a = left, let b = top { segments.append(Segment(a: a, b: b)) }
                        if let a = bottom, let b = right { segments.append(Segment(a: a, b: b)) }
                    }
                default:
                    break
                }
            }
        }
        return segments
    }

    private static func lerpEdge(
        _ p0: (x: Double, y: Double),
        _ v0: Double,
        _ p1: (x: Double, y: Double),
        _ v1: Double,
        _ level: Double
    ) -> Point2? {
        let d = v1 - v0
        if abs(d) < 1e-15 {
            return abs(v0 - level) < 1e-12
                ? Point2(x: (p0.x + p1.x) * 0.5, y: (p0.y + p1.y) * 0.5)
                : nil
        }
        let t = (level - v0) / d
        guard t >= -1e-9, t <= 1 + 1e-9 else { return nil }
        let u = min(max(t, 0), 1)
        return Point2(x: p0.x + (p1.x - p0.x) * u, y: p0.y + (p1.y - p0.y) * u)
    }

    private static func chainSegments(_ segments: [Segment]) -> [[Point2]] {
        guard !segments.isEmpty else { return [] }
        var adjacency: [Point2: [Point2]] = [:]
        for segment in segments {
            let a = segment.a.quantized()
            let b = segment.b.quantized()
            guard a != b else { continue }
            adjacency[a, default: []].append(b)
            adjacency[b, default: []].append(a)
        }

        var used: Set<UnorderedEdge> = []
        var chains: [[Point2]] = []

        func takeUnusedNeighbor(of point: Point2) -> Point2? {
            guard let neighbors = adjacency[point] else { return nil }
            for neighbor in neighbors {
                let edge = UnorderedEdge(point, neighbor)
                if !used.contains(edge) {
                    used.insert(edge)
                    return neighbor
                }
            }
            return nil
        }

        for start in adjacency.keys {
            // Prefer endpoints (degree 1) as chain starts.
            let degree = adjacency[start]?.count ?? 0
            guard degree == 1 || degree > 0 else { continue }
            if degree != 1 {
                // Skip interior starts until leftover loops.
                continue
            }
            guard let next = takeUnusedNeighbor(of: start) else { continue }
            var chain = [start, next]
            var current = next
            while let nxt = takeUnusedNeighbor(of: current) {
                chain.append(nxt)
                current = nxt
            }
            if chain.count >= 2 {
                chains.append(chain)
            }
        }

        // Remaining closed loops.
        for start in adjacency.keys {
            guard let next = takeUnusedNeighbor(of: start) else { continue }
            var chain = [start, next]
            var current = next
            while let nxt = takeUnusedNeighbor(of: current) {
                chain.append(nxt)
                current = nxt
                if current == start { break }
            }
            if chain.count >= 2 {
                chains.append(chain)
            }
        }
        return chains
    }

    private struct UnorderedEdge: Hashable {
        let a: Point2
        let b: Point2
        init(_ p: Point2, _ q: Point2) {
            if p.x < q.x || (p.x == q.x && p.y <= q.y) {
                a = p
                b = q
            } else {
                a = q
                b = p
            }
        }
    }

    private static func isUsable(
        map: HeightMap,
        x: Int,
        y: Int,
        configuration: ContourBuildConfiguration
    ) -> Bool {
        guard map.contains(x: x, y: y) else { return false }
        if configuration.requireKnownCell {
            let index = map.index(x: x, y: y)
            return map.measuredMask[index] || map.interpolatedMask[index]
        }
        return true
    }
}
