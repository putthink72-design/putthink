import Foundation

public enum TerrainPipelineError: LocalizedError, Equatable {
    case coincidentBallAndHole
    case noVertices
    case invalidCellSize
    case gridTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .coincidentBallAndHole:
            return "볼과 홀의 수평 거리가 너무 짧아 좌표계를 만들 수 없습니다."
        case .noVertices:
            return "래스터화할 메시 정점이 없습니다."
        case .invalidCellSize:
            return "격자 크기는 0보다 커야 합니다."
        case .gridTooLarge(let count):
            return "높이맵이 너무 큽니다(\(count)셀). 스캔 범위를 확인해 주세요."
        }
    }
}

public struct ScanCoordinateTransform: Sendable, Equatable {
    public let origin: ScanPose
    public let rightX: Double
    public let rightZ: Double
    public let forwardX: Double
    public let forwardZ: Double

    public init(ball: ScanPose, hole: ScanPose) throws {
        let dx = hole.worldX - ball.worldX
        let dz = hole.worldZ - ball.worldZ
        let length = hypot(dx, dz)
        guard length > 0.05 else {
            throw TerrainPipelineError.coincidentBallAndHole
        }
        origin = ball
        forwardX = dx / length
        forwardZ = dz / length
        // 골퍼/ARKit 화면 우측 = look × up (Y-up).
        // 이전 up × look 는 좌측이라 +β가 AR에서 왼쪽으로 그려지고 나침반(우+)과 어긋났다.
        rightX = -forwardZ
        rightZ = forwardX
    }

    public func local(vertex: ScanVertex, scanStart: TimeInterval, scanEnd: TimeInterval) -> LocalVertex {
        let dx = vertex.worldX - origin.worldX
        let dz = vertex.worldZ - origin.worldZ
        let duration = max(scanEnd - scanStart, 1e-9)
        let progress = min(max((vertex.timestamp - scanStart) / duration, 0), 1)
        return LocalVertex(
            x: dx * rightX + dz * rightZ,
            y: dx * forwardX + dz * forwardZ,
            height: vertex.worldY - origin.worldY,
            progress: progress
        )
    }
}

public enum DriftCorrector {
    public static func correct(_ vertices: [LocalVertex], drift: Double) -> [LocalVertex] {
        vertices.map { vertex in
            var corrected = vertex
            corrected.height -= drift * vertex.progress
            return corrected
        }
    }
}

public enum HeightMapRasterizer {
    /// 메시 구멍만 이웃 평균. 한쪽 스캔의 반대 플랭크는 경사 외삽.
    public static let maxInterpolationGapMeters = 0.10

    public static func rasterize(
        vertices: [LocalVertex],
        cellSize: Double = 0.05,
        maximumCellCount: Int = 1_000_000,
        fillMinX: Double? = nil,
        fillMaxX: Double? = nil,
        fillMinY: Double? = nil,
        fillMaxY: Double? = nil
    ) throws -> HeightMap {
        guard cellSize > 0 else { throw TerrainPipelineError.invalidCellSize }
        guard let first = vertices.first else { throw TerrainPipelineError.noVertices }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for vertex in vertices.dropFirst() {
            minX = min(minX, vertex.x)
            maxX = max(maxX, vertex.x)
            minY = min(minY, vertex.y)
            maxY = max(maxY, vertex.y)
        }
        if let fillMinX { minX = min(minX, fillMinX) }
        if let fillMaxX { maxX = max(maxX, fillMaxX) }
        if let fillMinY { minY = min(minY, fillMinY) }
        if let fillMaxY { maxY = max(maxY, fillMaxY) }

        let originX = floor(minX / cellSize) * cellSize
        let originY = floor(minY / cellSize) * cellSize
        let width = max(Int(ceil((maxX - originX) / cellSize)) + 1, 1)
        let height = max(Int(ceil((maxY - originY) / cellSize)) + 1, 1)
        let count = width * height
        guard count <= maximumCellCount else {
            throw TerrainPipelineError.gridTooLarge(count)
        }

        var buckets = Array(repeating: [Double](), count: count)
        for vertex in vertices {
            let x = min(max(Int(round((vertex.x - originX) / cellSize)), 0), width - 1)
            let y = min(max(Int(round((vertex.y - originY) / cellSize)), 0), height - 1)
            buckets[y * width + x].append(vertex.height)
        }

        var values = Array(repeating: 0.0, count: count)
        var measured = Array(repeating: false, count: count)
        for index in buckets.indices where !buckets[index].isEmpty {
            values[index] = median(buckets[index])
            measured[index] = true
        }
        let (filledValues, interpolated) = interpolateEmptyCells(
            values: values,
            knownMask: measured,
            width: width,
            height: height,
            cellSize: cellSize
        )

        return HeightMap(
            cellSize: cellSize,
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            values: filledValues,
            measuredMask: measured,
            interpolatedMask: interpolated
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func interpolateEmptyCells(
        values: [Double],
        knownMask: [Bool],
        width: Int,
        height: Int,
        cellSize: Double
    ) -> (values: [Double], interpolated: [Bool]) {
        var result = values
        var known = knownMask
        var interpolated = Array(repeating: false, count: values.count)
        guard known.contains(true) else { return (result, interpolated) }

        let (distance, nearest) = nearestMeasuredMap(
            knownMask: knownMask,
            width: width,
            height: height
        )
        let maxGapCells = max(1, Int((maxInterpolationGapMeters / cellSize).rounded(.up)))

        while true {
            var additions: [(index: Int, value: Double)] = []
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    guard !known[index], distance[index] <= maxGapCells else { continue }
                    var sum = 0.0
                    var weightSum = 0.0
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx
                            let ny = y + dy
                            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                            let neighbor = ny * width + nx
                            guard known[neighbor] else { continue }
                            let weight = (dx == 0 || dy == 0) ? 1.0 : 1.0 / sqrt(2)
                            sum += result[neighbor] * weight
                            weightSum += weight
                        }
                    }
                    if weightSum > 0 {
                        additions.append((index, sum / weightSum))
                    }
                }
            }
            guard !additions.isEmpty else { break }
            for addition in additions {
                result[addition.index] = addition.value
                known[addition.index] = true
                interpolated[addition.index] = true
            }
        }

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard !known[index] else { continue }
                let source = nearest[index]
                guard source >= 0 else { continue }
                let sx = source % width
                let sy = source / width
                let (gx, gy) = measuredGradient(
                    x: sx,
                    y: sy,
                    values: values,
                    measuredMask: knownMask,
                    width: width,
                    height: height,
                    cellSize: cellSize
                )
                let dx = Double(x - sx) * cellSize
                let dy = Double(y - sy) * cellSize
                result[index] = values[source] + gx * dx + gy * dy
                interpolated[index] = true
            }
        }
        return (result, interpolated)
    }

    private static func nearestMeasuredMap(
        knownMask: [Bool],
        width: Int,
        height: Int
    ) -> (distance: [Int], nearest: [Int]) {
        let count = width * height
        var distance = Array(repeating: Int.max, count: count)
        var nearest = Array(repeating: -1, count: count)
        var queue: [Int] = []
        queue.reserveCapacity(count / 4)
        for index in knownMask.indices where knownMask[index] {
            distance[index] = 0
            nearest[index] = index
            queue.append(index)
        }
        var head = 0
        let steps = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width
            let y = index / width
            for (dx, dy) in steps {
                let nx = x + dx
                let ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let neighbor = ny * width + nx
                let next = distance[index] + 1
                if next < distance[neighbor] {
                    distance[neighbor] = next
                    nearest[neighbor] = nearest[index]
                    queue.append(neighbor)
                }
            }
        }
        return (distance, nearest)
    }

    private static func measuredGradient(
        x: Int,
        y: Int,
        values: [Double],
        measuredMask: [Bool],
        width: Int,
        height: Int,
        cellSize: Double
    ) -> (Double, Double) {
        func measured(_ cx: Int, _ cy: Int) -> Double? {
            guard cx >= 0, cx < width, cy >= 0, cy < height else { return nil }
            let index = cy * width + cx
            guard measuredMask[index] else { return nil }
            return values[index]
        }
        let gx: Double
        if let right = measured(x + 1, y), let left = measured(x - 1, y) {
            gx = (right - left) / (2 * cellSize)
        } else if let right = measured(x + 1, y), let center = measured(x, y) {
            gx = (right - center) / cellSize
        } else if let left = measured(x - 1, y), let center = measured(x, y) {
            gx = (center - left) / cellSize
        } else {
            gx = 0
        }
        let gy: Double
        if let up = measured(x, y + 1), let down = measured(x, y - 1) {
            gy = (up - down) / (2 * cellSize)
        } else if let up = measured(x, y + 1), let center = measured(x, y) {
            gy = (up - center) / cellSize
        } else if let down = measured(x, y - 1), let center = measured(x, y) {
            gy = (center - down) / cellSize
        } else {
            gy = 0
        }
        return (gx, gy)
    }
}

public enum GaussianSmoother {
    public static func smooth(_ map: HeightMap, sigma: Double = 1.5) -> HeightMap {
        guard sigma > 0 else { return map }
        let radius = max(Int(ceil(3 * sigma)), 1)
        let kernel = (-radius...radius).map { offset in
            exp(-Double(offset * offset) / (2 * sigma * sigma))
        }
        let horizontal = convolve(
            values: map.values,
            width: map.width,
            height: map.height,
            kernel: kernel,
            radius: radius,
            horizontal: true
        )
        let vertical = convolve(
            values: horizontal,
            width: map.width,
            height: map.height,
            kernel: kernel,
            radius: radius,
            horizontal: false
        )
        var result = map
        result.values = vertical
        return result
    }

    private static func convolve(
        values: [Double],
        width: Int,
        height: Int,
        kernel: [Double],
        radius: Int,
        horizontal: Bool
    ) -> [Double] {
        var output = Array(repeating: 0.0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                var weightedSum = 0.0
                var weightSum = 0.0
                for offset in -radius...radius {
                    let sampleX = horizontal ? x + offset : x
                    let sampleY = horizontal ? y : y + offset
                    guard sampleX >= 0, sampleX < width, sampleY >= 0, sampleY < height else {
                        continue
                    }
                    let weight = kernel[offset + radius]
                    weightedSum += values[sampleY * width + sampleX] * weight
                    weightSum += weight
                }
                output[y * width + x] = weightedSum / max(weightSum, .leastNonzeroMagnitude)
            }
        }
        return output
    }
}

public enum GradientFieldBuilder {
    public static func build(from map: HeightMap) -> GradientField {
        var dx = Array(repeating: 0.0, count: map.cellCount)
        var dy = Array(repeating: 0.0, count: map.cellCount)

        for y in 0..<map.height {
            for x in 0..<map.width {
                let index = map.index(x: x, y: y)
                if map.width == 1 {
                    dx[index] = 0
                } else if x == 0 {
                    dx[index] = (map.value(x: 1, y: y) - map.value(x: 0, y: y)) / map.cellSize
                } else if x == map.width - 1 {
                    dx[index] = (map.value(x: x, y: y) - map.value(x: x - 1, y: y)) / map.cellSize
                } else {
                    dx[index] = (map.value(x: x + 1, y: y) - map.value(x: x - 1, y: y))
                        / (2 * map.cellSize)
                }

                if map.height == 1 {
                    dy[index] = 0
                } else if y == 0 {
                    dy[index] = (map.value(x: x, y: 1) - map.value(x: x, y: 0)) / map.cellSize
                } else if y == map.height - 1 {
                    dy[index] = (map.value(x: x, y: y) - map.value(x: x, y: y - 1)) / map.cellSize
                } else {
                    dy[index] = (map.value(x: x, y: y + 1) - map.value(x: x, y: y - 1))
                        / (2 * map.cellSize)
                }
            }
        }
        return GradientField(width: map.width, height: map.height, dx: dx, dy: dy)
    }
}

public struct TerrainPipelineResult: Codable, Sendable, Equatable {
    public let driftMeters: Double
    public let uncorrected: HeightMap
    public let corrected: HeightMap
    public let smoothed: HeightMap
    public let gradient: GradientField
    public let sigma: Double

    public init(
        driftMeters: Double,
        uncorrected: HeightMap,
        corrected: HeightMap,
        smoothed: HeightMap,
        gradient: GradientField,
        sigma: Double
    ) {
        self.driftMeters = driftMeters
        self.uncorrected = uncorrected
        self.corrected = corrected
        self.smoothed = smoothed
        self.gradient = gradient
        self.sigma = sigma
    }
}

public enum TerrainPipeline {
    /// - Parameters:
    ///   - startPose: 볼 지면 기준점(좌표계 원점). 카메라 위치가 아님.
    ///   - holePose: 홀 지면 기준점(로컬 +Y 방향).
    ///   - returnPose: 스캔 종료 시각용. 드리프트에는 `cameraReturnPose`가 우선.
    ///   - cameraStartPose: 볼 지정 직후 카메라 높이(드리프트). nil이면 startPose.worldY 사용.
    ///   - cameraReturnPose: 볼 복귀 시 카메라 높이(드리프트). nil이면 returnPose.worldY 사용.
    public static func process(
        vertices: [ScanVertex],
        startPose: ScanPose,
        holePose: ScanPose,
        returnPose: ScanPose,
        cellSize: Double = 0.05,
        sigma: Double = 1.5,
        cameraStartPose: ScanPose? = nil,
        cameraReturnPose: ScanPose? = nil
    ) throws -> TerrainPipelineResult {
        let transform = try ScanCoordinateTransform(ball: startPose, hole: holePose)
        let scanStart = (cameraStartPose ?? startPose).timestamp
        let scanEnd = (cameraReturnPose ?? returnPose).timestamp
        let local = vertices.map {
            transform.local(vertex: $0, scanStart: scanStart, scanEnd: scanEnd)
        }
        // 드리프트는 카메라 높이 변화만 사용한다. 지면 앵커 Y와 섞지 않는다.
        let cameraStartY = (cameraStartPose ?? startPose).worldY
        let cameraReturnY = (cameraReturnPose ?? returnPose).worldY
        let drift = cameraReturnY - cameraStartY
        let correctedVertices = DriftCorrector.correct(local, drift: drift)
        let margins = PuttScanCorridor.tuningMargins
        let holeDistance = hypot(
            holePose.worldX - startPose.worldX,
            holePose.worldZ - startPose.worldZ
        )
        let uncorrected = try HeightMapRasterizer.rasterize(
            vertices: local,
            cellSize: cellSize,
            fillMinX: -margins.lateralHalfWidth,
            fillMaxX: margins.lateralHalfWidth,
            fillMinY: -margins.ballEndMargin,
            fillMaxY: holeDistance + margins.pastHoleMargin
        )
        let corrected = try HeightMapRasterizer.rasterize(
            vertices: correctedVertices,
            cellSize: cellSize,
            fillMinX: -margins.lateralHalfWidth,
            fillMaxX: margins.lateralHalfWidth,
            fillMinY: -margins.ballEndMargin,
            fillMaxY: holeDistance + margins.pastHoleMargin
        )
        let smoothed = GaussianSmoother.smooth(corrected, sigma: sigma)
        let gradient = GradientFieldBuilder.build(from: smoothed)
        return TerrainPipelineResult(
            driftMeters: drift,
            uncorrected: uncorrected,
            corrected: corrected,
            smoothed: smoothed,
            gradient: gradient,
            sigma: sigma
        )
    }
}
