import Foundation
import simd

/// 표시 전용 정규 XZ 격자. TerrainPipeline / 볼·홀 앵커에 절대 주입하지 않는다.
/// ARKit 불규칙 삼각형 대신 5cm 사각 격자로 바닥·벽 윤곽이 읽히게 한다.
public enum DisplaySurfaceGrid {
    public static let cellSizeMeters: Float = 0.05
    public static let maxCells = 12_000

    public struct Cell: Sendable, Equatable {
        public var ix: Int32
        public var iz: Int32
        public var height: Float

        public init(ix: Int32, iz: Int32, height: Float) {
            self.ix = ix
            self.iz = iz
            self.height = height
        }

        public var key: Int64 {
            (Int64(ix) << 32) | Int64(UInt32(bitPattern: iz))
        }
    }

    public struct GeometryBuffers: Sendable, Equatable {
        public var positions: [SIMD3<Float>]
        public var indices: [UInt32]

        public init(positions: [SIMD3<Float>] = [], indices: [UInt32] = []) {
            self.positions = positions
            self.indices = indices
        }

        public var isEmpty: Bool { positions.isEmpty || indices.isEmpty }
    }

    public struct SplitMeshes: Sendable, Equatable {
        public var tentativeFill: GeometryBuffers
        public var tentativeLines: GeometryBuffers
        public var stableLines: GeometryBuffers

        public init(
            tentativeFill: GeometryBuffers = .init(),
            tentativeLines: GeometryBuffers = .init(),
            stableLines: GeometryBuffers = .init()
        ) {
            self.tentativeFill = tentativeFill
            self.tentativeLines = tentativeLines
            self.stableLines = stableLines
        }
    }

    public static func cellIndex(worldX: Float, worldZ: Float, cellSize: Float = cellSizeMeters) -> (Int32, Int32) {
        (Int32(floor(worldX / cellSize)), Int32(floor(worldZ / cellSize)))
    }

    /// 월드 정점을 5cm 셀에 모아 높이 중앙값을 만든다.
    public static func rasterize(
        worldPoints: [SIMD3<Float>],
        cellSize: Float = cellSizeMeters,
        maximumCells: Int = maxCells
    ) -> [Cell] {
        var buckets: [Int64: [Float]] = [:]
        buckets.reserveCapacity(min(worldPoints.count, maximumCells))
        for point in worldPoints where point.y.isFinite {
            let (ix, iz) = cellIndex(worldX: point.x, worldZ: point.z, cellSize: cellSize)
            let key = (Int64(ix) << 32) | Int64(UInt32(bitPattern: iz))
            buckets[key, default: []].append(point.y)
        }

        var cells: [Cell] = []
        cells.reserveCapacity(min(buckets.count, maximumCells))
        for (key, heights) in buckets {
            let ix = Int32(truncatingIfNeeded: key >> 32)
            let iz = Int32(bitPattern: UInt32(truncatingIfNeeded: key))
            cells.append(Cell(ix: ix, iz: iz, height: median(heights)))
            if cells.count >= maximumCells { break }
        }
        return cells
    }

    /// 표시용 국소 중앙값(3×3). 물리 입력에는 쓰지 않는다.
    public static func smoothDisplayOnly(_ cells: [Cell]) -> [Cell] {
        guard !cells.isEmpty else { return [] }
        var map: [Int64: Float] = [:]
        map.reserveCapacity(cells.count)
        for cell in cells {
            map[cell.key] = cell.height
        }
        return cells.map { cell in
            var neighbors: [Float] = []
            neighbors.reserveCapacity(9)
            for dz in Int32(-1)...1 {
                for dx in Int32(-1)...1 {
                    let key = (Int64(cell.ix &+ dx) << 32) | Int64(UInt32(bitPattern: cell.iz &+ dz))
                    if let height = map[key] {
                        neighbors.append(height)
                    }
                }
            }
            return Cell(ix: cell.ix, iz: cell.iz, height: median(neighbors))
        }
    }

    /// 커버리지 상태에 따라 파란 면/선과 흰 선 버퍼를 만든다.
    public static func buildSplitMeshes(
        cells: [Cell],
        coverage: ScanCoverageSnapshot,
        cellSize: Float = cellSizeMeters,
        lineHalfWidth: Float = 0.003
    ) -> SplitMeshes {
        guard !cells.isEmpty else { return SplitMeshes() }

        var heightMap: [Int64: Float] = [:]
        heightMap.reserveCapacity(cells.count)
        for cell in cells {
            heightMap[cell.key] = cell.height
        }

        var fill = GeometryBuffers()
        var tentativeLines = GeometryBuffers()
        var stableLines = GeometryBuffers()
        fill.positions.reserveCapacity(cells.count * 4)
        fill.indices.reserveCapacity(cells.count * 6)
        tentativeLines.positions.reserveCapacity(cells.count * 8)
        stableLines.positions.reserveCapacity(cells.count * 8)

        for cell in cells {
            let x0 = Float(cell.ix) * cellSize
            let z0 = Float(cell.iz) * cellSize
            let x1 = x0 + cellSize
            let z1 = z0 + cellSize
            let y00 = cell.height
            let rightKey = (Int64(cell.ix &+ 1) << 32) | Int64(UInt32(bitPattern: cell.iz))
            let upKey = (Int64(cell.ix) << 32) | Int64(UInt32(bitPattern: cell.iz &+ 1))
            let diagKey = (Int64(cell.ix &+ 1) << 32) | Int64(UInt32(bitPattern: cell.iz &+ 1))
            let y10 = heightMap[rightKey]
            let y01 = heightMap[upKey]
            let y11 = heightMap[diagKey]

            let state = coverage.state(worldX: x0 + cellSize * 0.5, worldZ: z0 + cellSize * 0.5, cellSize: cellSize)
            let isStable = state == .stable

            // 완전한 사각 셀만 면으로 채움 (미확정일 때).
            if !isStable, let y10, let y01, let y11 {
                let base = UInt32(fill.positions.count)
                fill.positions.append(contentsOf: [
                    SIMD3(x0, y00, z0),
                    SIMD3(x1, y10, z0),
                    SIMD3(x1, y11, z1),
                    SIMD3(x0, y01, z1)
                ])
                fill.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            }

            // 격자선: 오른쪽·위쪽 이웃이 있을 때만 그려 중복을 줄인다.
            if let y10 {
                if isStable {
                    appendRibbon(
                        a: SIMD3(x0, y00, z0),
                        b: SIMD3(x1, y10, z0),
                        halfWidth: lineHalfWidth,
                        into: &stableLines
                    )
                } else {
                    appendRibbon(
                        a: SIMD3(x0, y00, z0),
                        b: SIMD3(x1, y10, z0),
                        halfWidth: lineHalfWidth,
                        into: &tentativeLines
                    )
                }
            }
            if let y01 {
                if isStable {
                    appendRibbon(
                        a: SIMD3(x0, y00, z0),
                        b: SIMD3(x0, y01, z1),
                        halfWidth: lineHalfWidth,
                        into: &stableLines
                    )
                } else {
                    appendRibbon(
                        a: SIMD3(x0, y00, z0),
                        b: SIMD3(x0, y01, z1),
                        halfWidth: lineHalfWidth,
                        into: &tentativeLines
                    )
                }
            }
        }

        return SplitMeshes(
            tentativeFill: fill,
            tentativeLines: tentativeLines,
            stableLines: stableLines
        )
    }

    private static func appendRibbon(
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        halfWidth: Float,
        into buffers: inout GeometryBuffers
    ) {
        let dir = b - a
        let len = simd_length(dir)
        guard len > 0.001 else { return }
        let tangent = dir / len
        var side = simd_cross(tangent, SIMD3<Float>(0, 1, 0))
        if simd_length_squared(side) < 0.0001 {
            side = simd_cross(tangent, SIMD3<Float>(1, 0, 0))
        }
        guard simd_length_squared(side) >= 0.0001 else { return }
        side = simd_normalize(side) * halfWidth
        let base = UInt32(buffers.positions.count)
        buffers.positions.append(contentsOf: [a - side, a + side, b + side, b - side])
        buffers.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }
}
