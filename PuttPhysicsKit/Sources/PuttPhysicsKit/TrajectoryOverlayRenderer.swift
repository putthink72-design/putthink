import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct TrajectoryOverlayRequest: Sendable {
    public var terrainSamples: [[Double]]
    public var originX: Double
    public var originY: Double
    public var cellSize: Double
    public var trajectory: [PuttVector2]
    public var secondaryTrajectory: [PuttVector2]
    public var holePosition: PuttVector2
    public var boundaryY: Double?
    public var imageWidth: Int
    public var imageHeight: Int
    public var title: String

    public init(
        terrainSamples: [[Double]],
        originX: Double,
        originY: Double,
        cellSize: Double,
        trajectory: [PuttVector2],
        secondaryTrajectory: [PuttVector2] = [],
        holePosition: PuttVector2,
        boundaryY: Double? = nil,
        imageWidth: Int = 720,
        imageHeight: Int = 960,
        title: String
    ) {
        self.terrainSamples = terrainSamples
        self.originX = originX
        self.originY = originY
        self.cellSize = cellSize
        self.trajectory = trajectory
        self.secondaryTrajectory = secondaryTrajectory
        self.holePosition = holePosition
        self.boundaryY = boundaryY
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.title = title
    }
}

public enum TrajectoryOverlayRenderer {
    public static func makeImage(request: TrajectoryOverlayRequest) -> CGImage? {
        let width = request.imageWidth
        let height = request.imageHeight
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let rows = request.terrainSamples.count
        let columns = request.terrainSamples.first?.count ?? 0
        guard rows > 0, columns > 0 else { return context.makeImage() }

        var minHeight = Double.greatestFiniteMagnitude
        var maxHeight = -Double.greatestFiniteMagnitude
        for row in request.terrainSamples {
            for value in row {
                minHeight = min(minHeight, value)
                maxHeight = max(maxHeight, value)
            }
        }
        let span = max(maxHeight - minHeight, 1e-9)
        let worldMaxX = request.originX + Double(columns - 1) * request.cellSize
        let worldMaxY = request.originY + Double(rows - 1) * request.cellSize

        func project(_ point: PuttVector2) -> CGPoint {
            let u = (point.x - request.originX) / max(worldMaxX - request.originX, 1e-9)
            let v = (point.y - request.originY) / max(worldMaxY - request.originY, 1e-9)
            return CGPoint(
                x: CGFloat(u) * CGFloat(width - 1),
                y: CGFloat(v) * CGFloat(height - 1)
            )
        }

        let cellWidth = CGFloat(width) / CGFloat(columns)
        let cellHeight = CGFloat(height) / CGFloat(rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let normalized = (request.terrainSamples[row][column] - minHeight) / span
                let color = heatColor(normalized)
                context.setFillColor(color)
                context.fill(
                    CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth + 1,
                        height: cellHeight + 1
                    )
                )
            }
        }

        if let boundaryY = request.boundaryY {
            let start = project(PuttVector2(x: request.originX, y: boundaryY))
            let end = project(PuttVector2(x: worldMaxX, y: boundaryY))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
            context.setLineWidth(2)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }

        if request.trajectory.count >= 2 {
            context.setStrokeColor(CGColor(red: 0.1, green: 0.95, blue: 0.35, alpha: 1))
            context.setLineWidth(3)
            context.move(to: project(request.trajectory[0]))
            for point in request.trajectory.dropFirst() {
                context.addLine(to: project(point))
            }
            context.strokePath()
        }

        if request.secondaryTrajectory.count >= 2 {
            context.setStrokeColor(CGColor(red: 0.95, green: 0.85, blue: 0.2, alpha: 1))
            context.setLineWidth(2)
            context.move(to: project(request.secondaryTrajectory[0]))
            for point in request.secondaryTrajectory.dropFirst() {
                context.addLine(to: project(point))
            }
            context.strokePath()
        }

        let start = project(PuttVector2(x: 0, y: 0))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10))

        let hole = project(request.holePosition)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: hole.x - 6, y: hole.y - 6, width: 12, height: 12))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(x: hole.x - 6, y: hole.y - 6, width: 12, height: 12))

        return context.makeImage()
    }

    public static func writePNG(request: TrajectoryOverlayRequest, to url: URL) throws {
        guard let image = makeImage(request: request) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
        guard let destination else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public static func sampleTerrain(
        _ terrain: some TerrainField,
        originX: Double,
        originY: Double,
        widthMeters: Double,
        heightMeters: Double,
        cellSize: Double
    ) -> [[Double]] {
        let columns = max(Int(ceil(widthMeters / cellSize)) + 1, 2)
        let rows = max(Int(ceil(heightMeters / cellSize)) + 1, 2)
        var samples: [[Double]] = []
        for row in 0..<rows {
            var line: [Double] = []
            for column in 0..<columns {
                let point = PuttVector2(
                    x: originX + Double(column) * cellSize,
                    y: originY + Double(row) * cellSize
                )
                line.append(terrain.height(at: point))
            }
            samples.append(line)
        }
        return samples
    }

    private static func heatColor(_ value: Double) -> CGColor {
        let t = min(max(value, 0), 1)
        return CGColor(
            red: CGFloat(0.15 + 0.75 * t),
            green: CGFloat(0.55 - 0.25 * t),
            blue: CGFloat(0.35 * (1 - t)),
            alpha: 1
        )
    }
}
