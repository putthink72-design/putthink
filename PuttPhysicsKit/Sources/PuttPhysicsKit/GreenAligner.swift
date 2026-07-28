import Foundation

public struct GreenAlignment: Sendable, Equatable {
    public var ballWorld: PuttVector2
    public var holeWorld: PuttVector2
    public var forwardX: Double
    public var forwardY: Double
    public var rightX: Double
    public var rightY: Double
    public var holeDistance: Double

    public init(
        ballWorld: PuttVector2,
        holeWorld: PuttVector2,
        forwardX: Double,
        forwardY: Double,
        rightX: Double,
        rightY: Double,
        holeDistance: Double
    ) {
        self.ballWorld = ballWorld
        self.holeWorld = holeWorld
        self.forwardX = forwardX
        self.forwardY = forwardY
        self.rightX = rightX
        self.rightY = rightY
        self.holeDistance = holeDistance
    }

    public func local(world: PuttVector2) -> PuttVector2 {
        let dx = world.x - ballWorld.x
        let dy = world.y - ballWorld.y
        return PuttVector2(
            x: dx * rightX + dy * rightY,
            y: dx * forwardX + dy * forwardY
        )
    }
}

public enum GreenAligner {
    /// 볼→홀을 +Y로 두는 정렬을 만든 뒤, 기존 스무딩·기울기 파이프라인으로 TerrainField를 생성한다.
    public static func makeTerrainField(
        from green: GreenHeightmap,
        ballWorld: PuttVector2,
        holeWorld: PuttVector2,
        sigma: Double = 1.5,
        outputCellSize: Double? = nil
    ) throws -> (alignment: GreenAlignment, field: HeightMapTerrainField) {
        let alignment = try makeAlignment(ballWorld: ballWorld, holeWorld: holeWorld)
        let cellSize = outputCellSize ?? green.cellSize
        let heightMap = try resampleToLocalHeightMap(
            green: green,
            alignment: alignment,
            cellSize: cellSize
        )
        let smoothed = GaussianSmoother.smooth(heightMap, sigma: sigma)
        let gradient = GradientFieldBuilder.build(from: smoothed)
        return (alignment, HeightMapTerrainField(heightMap: smoothed, gradientField: gradient))
    }

    public static func makeAlignment(
        ballWorld: PuttVector2,
        holeWorld: PuttVector2
    ) throws -> GreenAlignment {
        let dx = holeWorld.x - ballWorld.x
        let dy = holeWorld.y - ballWorld.y
        let length = hypot(dx, dy)
        guard length > 0.05 else { throw TerrainPipelineError.coincidentBallAndHole }
        let forwardX = dx / length
        let forwardY = dy / length
        return GreenAlignment(
            ballWorld: ballWorld,
            holeWorld: holeWorld,
            forwardX: forwardX,
            forwardY: forwardY,
            rightX: forwardY,
            rightY: -forwardX,
            holeDistance: length
        )
    }

    /// 유효 셀 중심을 기준으로 가장자리 볼 1곳 + 내부 홀 후보를 만든다.
    public static func defaultScenarios(
        for green: GreenHeightmap,
        holeCount: Int = 3
    ) throws -> [(ball: PuttVector2, hole: PuttVector2)] {
        let centroid = try green.validCentroid()
        var farthest = centroid
        var farthestDistance = -1.0
        for row in 0..<green.height {
            for column in 0..<green.width where !green.isMissing(column: column, row: row) {
                let point = PuttVector2(x: green.worldX(column: column), y: green.worldY(row: row))
                let distance = hypot(point.x - centroid.x, point.y - centroid.y)
                if distance > farthestDistance {
                    farthestDistance = distance
                    farthest = point
                }
            }
        }

        let edgeDirectionX = farthest.x - centroid.x
        let edgeDirectionY = farthest.y - centroid.y
        let edgeLength = max(hypot(edgeDirectionX, edgeDirectionY), 1e-9)
        let unitX = edgeDirectionX / edgeLength
        let unitY = edgeDirectionY / edgeLength
        let puttLength = min(max(0.55 * farthestDistance, 3.0), 8.0)

        let ball = nearestValidWorld(
            green,
            to: PuttVector2(
                x: centroid.x - 0.5 * puttLength * unitX,
                y: centroid.y - 0.5 * puttLength * unitY
            )
        )

        var holes: [PuttVector2] = [
            nearestValidWorld(
                green,
                to: PuttVector2(
                    x: ball.x + puttLength * unitX,
                    y: ball.y + puttLength * unitY
                )
            )
        ]
        if holeCount > 1 {
            let perpendicularX = -unitY
            let perpendicularY = unitX
            holes.append(
                nearestValidWorld(
                    green,
                    to: PuttVector2(
                        x: ball.x + puttLength * (0.85 * unitX + 0.25 * perpendicularX),
                        y: ball.y + puttLength * (0.85 * unitY + 0.25 * perpendicularY)
                    )
                )
            )
        }
        if holeCount > 2 {
            holes.append(nearestValidWorld(green, to: centroid))
        }

        return Array(holes.prefix(holeCount)).map { (ball: ball, hole: $0) }
    }

    private static func resampleToLocalHeightMap(
        green: GreenHeightmap,
        alignment: GreenAlignment,
        cellSize: Double
    ) throws -> HeightMap {
        let ballHeight = nearestValidHeight(green, to: alignment.ballWorld)
        var locals: [LocalVertex] = []
        locals.reserveCapacity(green.cellCount)
        for row in 0..<green.height {
            for column in 0..<green.width {
                guard let height = green.heightMeters(column: column, row: row) else { continue }
                let world = PuttVector2(x: green.worldX(column: column), y: green.worldY(row: row))
                let local = alignment.local(world: world)
                locals.append(
                    LocalVertex(
                        x: local.x,
                        y: local.y,
                        height: height - ballHeight,
                        progress: 0
                    )
                )
            }
        }
        guard !locals.isEmpty else { throw GreenHeightmapError.emptyValidCells }
        return try HeightMapRasterizer.rasterize(vertices: locals, cellSize: cellSize)
    }

    private static func nearestValidWorld(_ green: GreenHeightmap, to point: PuttVector2) -> PuttVector2 {
        var best = point
        var bestDistance = Double.greatestFiniteMagnitude
        for row in 0..<green.height {
            for column in 0..<green.width where !green.isMissing(column: column, row: row) {
                let candidate = PuttVector2(x: green.worldX(column: column), y: green.worldY(row: row))
                let distance = hypot(candidate.x - point.x, candidate.y - point.y)
                if distance < bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
        }
        return best
    }

    private static func nearestValidHeight(_ green: GreenHeightmap, to point: PuttVector2) -> Double {
        let world = nearestValidWorld(green, to: point)
        let column = Int(round((world.x - green.originX) / green.cellSize))
        let row = Int(round((world.y - green.originY) / green.cellSize))
        return green.heightMeters(
            column: min(max(column, 0), green.width - 1),
            row: min(max(row, 0), green.height - 1)
        ) ?? 0
    }
}
