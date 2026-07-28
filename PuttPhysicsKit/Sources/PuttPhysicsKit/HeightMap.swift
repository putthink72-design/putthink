import Foundation

public struct ScanVertex: Codable, Sendable, Equatable {
    public var worldX: Double
    public var worldY: Double
    public var worldZ: Double
    public var timestamp: TimeInterval

    public init(worldX: Double, worldY: Double, worldZ: Double, timestamp: TimeInterval) {
        self.worldX = worldX
        self.worldY = worldY
        self.worldZ = worldZ
        self.timestamp = timestamp
    }
}

public struct ScanPose: Codable, Sendable, Equatable {
    public var worldX: Double
    public var worldY: Double
    public var worldZ: Double
    public var timestamp: TimeInterval

    public init(worldX: Double, worldY: Double, worldZ: Double, timestamp: TimeInterval) {
        self.worldX = worldX
        self.worldY = worldY
        self.worldZ = worldZ
        self.timestamp = timestamp
    }
}

public struct LocalVertex: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var height: Double
    public var progress: Double

    public init(x: Double, y: Double, height: Double, progress: Double) {
        self.x = x
        self.y = y
        self.height = height
        self.progress = progress
    }
}

public struct HeightMap: Codable, Sendable, Equatable {
    public let cellSize: Double
    public let originX: Double
    public let originY: Double
    public let width: Int
    public let height: Int
    public var values: [Double]
    public var measuredMask: [Bool]
    public var interpolatedMask: [Bool]

    public init(
        cellSize: Double,
        originX: Double,
        originY: Double,
        width: Int,
        height: Int,
        values: [Double],
        measuredMask: [Bool],
        interpolatedMask: [Bool]
    ) {
        precondition(width > 0 && height > 0)
        precondition(values.count == width * height)
        precondition(measuredMask.count == values.count)
        precondition(interpolatedMask.count == values.count)
        self.cellSize = cellSize
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.values = values
        self.measuredMask = measuredMask
        self.interpolatedMask = interpolatedMask
    }

    public var cellCount: Int { width * height }

    public var emptyCellRatio: Double {
        guard cellCount > 0 else { return 1 }
        return Double(measuredMask.filter { !$0 }.count) / Double(cellCount)
    }

    public func index(x: Int, y: Int) -> Int {
        y * width + x
    }

    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height
    }

    public func value(x: Int, y: Int) -> Double {
        values[index(x: x, y: y)]
    }

    public mutating func setValue(_ value: Double, x: Int, y: Int) {
        values[index(x: x, y: y)] = value
    }

    public func worldCoordinate(x: Int, y: Int) -> (x: Double, y: Double) {
        (originX + Double(x) * cellSize, originY + Double(y) * cellSize)
    }
}

public struct GradientField: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var dx: [Double]
    public var dy: [Double]

    public init(width: Int, height: Int, dx: [Double], dy: [Double]) {
        precondition(dx.count == width * height && dy.count == width * height)
        self.width = width
        self.height = height
        self.dx = dx
        self.dy = dy
    }

    public func gradient(x: Int, y: Int) -> (dx: Double, dy: Double) {
        let index = y * width + x
        return (dx[index], dy[index])
    }
}

public struct NormalizedRegion: Codable, Sendable, Equatable {
    public var minX: Double
    public var maxX: Double
    public var minY: Double
    public var maxY: Double

    public init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.minX = min(max(minX, 0), 1)
        self.maxX = min(max(maxX, 0), 1)
        self.minY = min(max(minY, 0), 1)
        self.maxY = min(max(maxY, 0), 1)
    }

    public static let center = NormalizedRegion(minX: 0.3, maxX: 0.7, minY: 0.3, maxY: 0.7)
}
