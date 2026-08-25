import Foundation
import simd

/// 고신뢰 sceneDepth를 시간축으로 융합하는 순수 코어.
/// XZ 셀마다 프레임별 대표 높이를 저장하고 median/MAD로 순간 노이즈를 제거한다.
public final class TemporalSurfaceFusion {
    public struct Sample: Sendable, Equatable {
        public let worldX: Double
        public let worldY: Double
        public let worldZ: Double
        public let timestamp: TimeInterval

        public init(worldX: Double, worldY: Double, worldZ: Double, timestamp: TimeInterval) {
            self.worldX = worldX
            self.worldY = worldY
            self.worldZ = worldZ
            self.timestamp = timestamp
        }
    }

    /// 5cm 높이맵보다 촘촘하되, 12m 편도에서 1cm×4.5만 셀이면 볼 쪽을 너무 일찍 버린다.
    public static let defaultCellSize = 0.02
    public static let minimumFramesPerCell = 3
    public static let maximumFramesPerCell = 24
    /// 약 36m² @ 2cm — 12m × 한쪽 3m 편도 스트립.
    public static let defaultMaximumCellCount = 90_000
    /// 서로 다른 카메라 위치에서 관측돼야 grazing-angle 편향을 제거할 수 있다.
    public static let minimumViewpoints = 2
    public static let viewpointSeparation = 0.12

    private struct Cell {
        var heights: [Double] = []
        var timestamps: [TimeInterval] = []
        /// 각 프레임 관측의 카메라 XZ (다중 시점 판정용). 없으면 nil.
        var cameras: [SIMD2<Double>?] = []
        var lastTimestamp: TimeInterval = 0
    }

    private let cellSize: Double
    private let maximumCellCount: Int
    private var cells: [Int64: Cell] = [:]

    public init(
        cellSize: Double = defaultCellSize,
        maximumCellCount: Int = defaultMaximumCellCount
    ) {
        precondition(cellSize > 0)
        precondition(maximumCellCount > 0)
        self.cellSize = cellSize
        self.maximumCellCount = maximumCellCount
    }

    public func reset() {
        cells.removeAll(keepingCapacity: true)
    }

    /// 한 프레임에서 같은 XZ 셀에 들어온 픽셀은 가장 낮은 표면 하나로 합친다.
    /// 실내 벽/가구가 같은 XZ에 겹쳐도 지면을 선택하고, 프레임 간 이상치는 MAD로 제거한다.
    /// `cameraXZ`를 주면 서로 다른 시점 관측만 유효 프레임으로 인정한다.
    public func ingestFrame(
        _ samples: [Sample],
        timestamp: TimeInterval,
        cameraXZ: SIMD2<Double>? = nil,
        keepNearBallXZ: SIMD2<Double>? = nil,
        keepNearPathEndXZ: SIMD2<Double>? = nil
    ) {
        var frameBuckets: [Int64: [Double]] = [:]
        for sample in samples where sample.worldY.isFinite {
            let key = Self.cellKey(x: sample.worldX, z: sample.worldZ, cellSize: cellSize)
            frameBuckets[key, default: []].append(sample.worldY)
        }

        for (key, heights) in frameBuckets {
            var cell = cells[key] ?? Cell()
            guard let groundCandidate = heights.min() else { continue }
            cell.heights.append(groundCandidate)
            cell.timestamps.append(timestamp)
            cell.cameras.append(cameraXZ)
            cell.lastTimestamp = timestamp
            if cell.heights.count > Self.maximumFramesPerCell {
                let overflow = cell.heights.count - Self.maximumFramesPerCell
                cell.heights.removeFirst(overflow)
                cell.timestamps.removeFirst(overflow)
                cell.cameras.removeFirst(overflow)
            }
            cells[key] = cell
        }
        pruneIfNeeded(
            keepingNear: cameraXZ,
            keepNearBallXZ: keepNearBallXZ,
            keepNearPathEndXZ: keepNearPathEndXZ ?? cameraXZ,
            now: timestamp
        )
    }

    /// 볼이 있으면 볼→카메라 구간 밖의 셀부터 버린다. 카메라 거리만 쓰면 홀 도착 때 볼 쪽 경사가 사라진다.
    private func pruneIfNeeded(
        keepingNear cameraXZ: SIMD2<Double>?,
        keepNearBallXZ: SIMD2<Double>?,
        keepNearPathEndXZ: SIMD2<Double>?,
        now: TimeInterval
    ) {
        guard cells.count > maximumCellCount else { return }
        let overflow = cells.count - maximumCellCount
        let pathEnd = keepNearPathEndXZ ?? cameraXZ
        let ranked = cells.map { key, cell -> (Int64, Double) in
            let center = Self.cellCenter(key: key, cellSize: cellSize)
            let dist: Double
            if let ball = keepNearBallXZ, let pathEnd {
                dist = Self.distanceToSegment(
                    px: center.x,
                    pz: center.z,
                    ax: ball.x,
                    az: ball.y,
                    bx: pathEnd.x,
                    bz: pathEnd.y
                )
            } else if let cameraXZ {
                dist = hypot(center.x - cameraXZ.x, center.z - cameraXZ.y)
            } else {
                dist = 0
            }
            let age = max(0, now - cell.lastTimestamp)
            return (key, dist + age * 0.15)
        }
        .sorted { $0.1 > $1.1 }
        for index in 0..<overflow {
            cells.removeValue(forKey: ranked[index].0)
        }
    }

    /// 볼·홀 주변의 지면만 선택해 융합 정점을 만든다.
    /// 평면을 강제하지 않으므로 그린의 장거리 경사와 브레이크는 유지한다.
    public func fusedVertices(
        referenceHeight: Double,
        ballX: Double,
        ballZ: Double,
        holeX: Double,
        holeZ: Double,
        lateralMargin: Double = PuttScanCorridor.tuningMargins.lateralHalfWidth,
        ballEndMargin: Double = PuttScanCorridor.tuningMargins.ballEndMargin,
        pastHoleMargin: Double = PuttScanCorridor.tuningMargins.pastHoleMargin,
        heightTolerance: Double = 0.30
    ) -> [ScanVertex] {
        var output: [ScanVertex] = []
        output.reserveCapacity(cells.count)

        for (key, cell) in cells where cell.heights.count >= Self.minimumFramesPerCell {
            let center = Self.cellCenter(key: key, cellSize: cellSize)
            guard Self.isInsideCorridor(
                x: center.x,
                z: center.z,
                ballX: ballX,
                ballZ: ballZ,
                holeX: holeX,
                holeZ: holeZ,
                lateralMargin: lateralMargin,
                ballEndMargin: ballEndMargin,
                pastHoleMargin: pastHoleMargin
            ) else { continue }

            // 지면 근처 프레임만 인덱스 단위로 골라 카메라 시점 정보를 유지한다.
            let nearIndices = cell.heights.indices.filter {
                abs(cell.heights[$0] - referenceHeight) <= heightTolerance
            }
            guard nearIndices.count >= Self.minimumFramesPerCell else { continue }

            let nearGround = nearIndices.map { cell.heights[$0] }
            let centerHeight = Self.median(nearGround)
            let deviations = nearGround.map { abs($0 - centerHeight) }
            let mad = Self.median(deviations)
            // LiDAR 저노이즈 구간은 최소 4mm 허용, 거친 구간은 MAD의 3배.
            let threshold = max(0.004, mad * 3)
            let inlierIndices = nearIndices.filter {
                abs(cell.heights[$0] - centerHeight) <= threshold
            }
            guard inlierIndices.count >= Self.minimumFramesPerCell else { continue }

            // 카메라 정보가 있으면 서로 다른 시점 2곳 이상에서 본 셀만 채택한다.
            let inlierCameras = inlierIndices.compactMap { cell.cameras[$0] }
            if !inlierCameras.isEmpty {
                let distinct = Self.distinctViewpointCount(
                    inlierCameras,
                    separation: Self.viewpointSeparation
                )
                guard distinct >= Self.minimumViewpoints else { continue }
            }

            let inlierHeights = inlierIndices.map { cell.heights[$0] }
            let timestamp = Self.median(inlierIndices.map { cell.timestamps[$0] })
            output.append(
                ScanVertex(
                    worldX: center.x,
                    worldY: Self.median(inlierHeights),
                    worldZ: center.z,
                    timestamp: timestamp
                )
            )
        }
        return output
    }

    public var observedCellCount: Int { cells.count }

    private static func cellKey(x: Double, z: Double, cellSize: Double) -> Int64 {
        let ix = Int32(floor(x / cellSize))
        let iz = Int32(floor(z / cellSize))
        return (Int64(ix) << 32) | Int64(UInt32(bitPattern: iz))
    }

    private static func cellCenter(key: Int64, cellSize: Double) -> (x: Double, z: Double) {
        let ix = Int32(truncatingIfNeeded: key >> 32)
        let iz = Int32(bitPattern: UInt32(truncatingIfNeeded: key))
        return (
            (Double(ix) + 0.5) * cellSize,
            (Double(iz) + 0.5) * cellSize
        )
    }

    private static func isInsideCorridor(
        x: Double,
        z: Double,
        ballX: Double,
        ballZ: Double,
        holeX: Double,
        holeZ: Double,
        lateralMargin: Double,
        ballEndMargin: Double,
        pastHoleMargin: Double
    ) -> Bool {
        let dx = holeX - ballX
        let dz = holeZ - ballZ
        let length = hypot(dx, dz)
        guard length > 0.05 else { return false }
        let forwardX = dx / length
        let forwardZ = dz / length
        let px = x - ballX
        let pz = z - ballZ
        let along = px * forwardX + pz * forwardZ
        let lateral = abs(px * forwardZ - pz * forwardX)
        return along >= -ballEndMargin
            && along <= length + pastHoleMargin
            && lateral <= lateralMargin
    }

    static func distanceToSegment(
        px: Double,
        pz: Double,
        ax: Double,
        az: Double,
        bx: Double,
        bz: Double
    ) -> Double {
        let abx = bx - ax
        let abz = bz - az
        let lengthSquared = abx * abx + abz * abz
        if lengthSquared < 1e-12 {
            return hypot(px - ax, pz - az)
        }
        let t = min(max(((px - ax) * abx + (pz - az) * abz) / lengthSquared, 0), 1)
        return hypot(px - ax - t * abx, pz - az - t * abz)
    }

    /// 최소 분리 거리 이상 떨어진 카메라 위치를 그리디로 군집화해 개수를 센다.
    static func distinctViewpointCount(_ cameras: [SIMD2<Double>], separation: Double) -> Int {
        var representatives: [SIMD2<Double>] = []
        for camera in cameras {
            let isNew = representatives.allSatisfy { simd_distance($0, camera) >= separation }
            if isNew { representatives.append(camera) }
        }
        return representatives.count
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
