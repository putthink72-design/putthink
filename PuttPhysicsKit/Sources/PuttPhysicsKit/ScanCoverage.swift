import Foundation
import simd

/// Polycam형 실시간 커버리지 — 순수 코어 (ARKit 비의존).
/// UI 피드백 전용. TerrainPipeline / 볼·홀 앵커에 주입하지 않는다.
public enum ScanCoverageCellState: String, Sendable, Codable, Equatable {
    case unseen
    case tentative
    case stable
}

public enum ScanCoverageQuality: String, Sendable, Codable, Equatable {
    case normal
    case tooFast
    case tooClose
    case tooFar
    case trackingBad

    public var message: String {
        switch self {
        case .normal:
            return "천천히 이동하며 분홍 격자를 흰색으로 채우세요."
        case .tooFast:
            return "움직임이 빠릅니다. 보행 속도로 천천히 이동하세요."
        case .tooClose:
            return "너무 가깝습니다. 바닥에서 약간 거리를 두세요."
        case .tooFar:
            return "너무 멉니다. 그린 바닥이 화면에 더 크게 들어오게 하세요."
        case .trackingBad:
            return "트래킹이 불안정합니다. 잔디 특징이 보이게 천천히 움직이세요."
        }
    }
}

public struct ScanCoveragePoint: Sendable, Equatable {
    public var worldX: Float
    public var worldY: Float
    public var worldZ: Float
    /// 0=low, 1=medium, 2=high (ARConfidenceLevel raw)
    public var confidence: UInt8

    public init(worldX: Float, worldY: Float, worldZ: Float, confidence: UInt8) {
        self.worldX = worldX
        self.worldY = worldY
        self.worldZ = worldZ
        self.confidence = confidence
    }
}

public struct ScanCoverageSnapshot: Sendable, Equatable {
    public var observedCellCount: Int
    public var stableCellCount: Int
    public var tentativeCellCount: Int
    public var newlyStabilizedCount: Int
    public var quality: ScanCoverageQuality
    public var meanDepthMeters: Float
    public var cameraSpeedMetersPerSecond: Float
    /// 안정 셀 좌표 키 집합 (cellKey = pack(ix, iz))
    public var stableKeys: Set<Int64>
    public var tentativeKeys: Set<Int64>
    /// 표시용 셀 높이(월드 Y). 물리에는 쓰지 않는다.
    public var cellHeights: [Int64: Float]
    /// 표시용 셀 실제 XZ(월드). 5cm 키 대신 이 점으로 바둑판을 붙여 원점 밀림 때 옆 칸이 생기지 않게 한다.
    public var cellCenters: [Int64: SIMD2<Float>]

    public var stableRatio: Double {
        guard observedCellCount > 0 else { return 0 }
        return Double(stableCellCount) / Double(observedCellCount)
    }

    public var statusLine: String {
        let pct = Int((stableRatio * 100).rounded())
        return "커버리지 \(pct)% · 안정 \(stableCellCount) / 관측 \(observedCellCount)"
    }

    public func state(worldX: Float, worldZ: Float, cellSize: Float = ScanCoverage.cellSizeMeters) -> ScanCoverageCellState {
        let key = ScanCoverage.cellKey(worldX: worldX, worldZ: worldZ, cellSize: cellSize)
        if stableKeys.contains(key) { return .stable }
        if tentativeKeys.contains(key) { return .tentative }
        return .unseen
    }

    public static let empty = ScanCoverageSnapshot(
        observedCellCount: 0,
        stableCellCount: 0,
        tentativeCellCount: 0,
        newlyStabilizedCount: 0,
        quality: .normal,
        meanDepthMeters: 0,
        cameraSpeedMetersPerSecond: 0,
        stableKeys: [],
        tentativeKeys: [],
        cellHeights: [:],
        cellCenters: [:]
    )
}

/// 5cm XZ 셀별 관측을 누적하고 Polycam형 파랑→흰 전환 상태를 판정한다.
public final class ScanCoverage {
    public static let cellSizeMeters: Float = 0.05
    public static let minConfidence: UInt8 = 1 // medium+
    public static let observationsForStable = 3
    public static let minDepthMeters: Float = 0.25
    /// iPhone LiDAR 실사용 거리. 편도·한쪽 스캔에서 라인 건너편을 보기 위해 3.5m보다 넓게 둔다.
    public static let maxDepthMeters: Float = 5.0
    public static let tooCloseMeters: Float = 0.35
    public static let tooFarMeters: Float = 4.5
    public static let tooFastMetersPerSecond: Float = 1.2
    public static let maxCells = 40_000

    private struct Cell {
        var hitCount: UInt16 = 0
        var lastTimestamp: TimeInterval = 0
        var maxConfidence: UInt8 = 0
        var lastX: Float = 0
        var lastY: Float = 0
        var lastZ: Float = 0
    }

    private var cells: [Int64: Cell] = [:]
    private var previousCameraPosition: SIMD3<Float>?
    private var previousTimestamp: TimeInterval?

    public init() {}

    public func reset() {
        cells.removeAll(keepingCapacity: true)
        previousCameraPosition = nil
        previousTimestamp = nil
    }

    public static func cellKey(worldX: Float, worldZ: Float, cellSize: Float = cellSizeMeters) -> Int64 {
        let ix = Int32((worldX / cellSize).rounded(.down))
        let iz = Int32((worldZ / cellSize).rounded(.down))
        return (Int64(ix) << 32) | Int64(UInt32(bitPattern: iz))
    }

    /// 카메라 공간 깊이 픽셀을 월드 좌표로 변환.
    /// `intrinsics`는 depth 해상도 기준 [[fx,0,0],[0,fy,0],[cx,cy,1]] column-major와 동일한 3×3.
    /// `cameraToWorld`는 ARCamera.transform.
    public static func unproject(
        depthX: Float,
        depthY: Float,
        depthMeters: Float,
        intrinsics: simd_float3x3,
        cameraToWorld: simd_float4x4
    ) -> SIMD3<Float>? {
        guard depthMeters.isFinite,
              depthMeters >= minDepthMeters,
              depthMeters <= maxDepthMeters
        else { return nil }
        let fx = intrinsics[0, 0]
        let fy = intrinsics[1, 1]
        let cx = intrinsics[2, 0]
        let cy = intrinsics[2, 1]
        guard fx > 0, fy > 0 else { return nil }
        // ARKit 이미지 원점은 왼쪽 위(+Y 아래). 카메라 공간은 +Y 위, -Z 전방.
        let x = (depthX - cx) * depthMeters / fx
        let y = -((depthY - cy) * depthMeters / fy)
        let local = SIMD4<Float>(x, y, -depthMeters, 1)
        let world = cameraToWorld * local
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    @discardableResult
    public func ingest(
        points: [ScanCoveragePoint],
        cameraPosition: SIMD3<Float>,
        timestamp: TimeInterval,
        trackingLimited: Bool
    ) -> ScanCoverageSnapshot {
        var newlyStable = 0
        var depthSum: Float = 0
        var depthCount = 0

        var speed: Float = 0
        if let previousCameraPosition, let previousTimestamp, timestamp > previousTimestamp {
            let dt = Float(timestamp - previousTimestamp)
            if dt > 0.001 {
                speed = simd_length(cameraPosition - previousCameraPosition) / dt
            }
        }
        previousCameraPosition = cameraPosition
        previousTimestamp = timestamp

        // 트래킹이 깨진 프레임의 역투영은 카메라에 붙어 격자가 흐른다. 기존 셀은 유지.
        if !trackingLimited {
            // 같은 프레임·같은 셀의 여러 픽셀은 1회 관측으로만 센다.
            // (한 프레임 3픽셀로 바로 "안정"이 되는 오판정 방지)
            var frameBuckets: [Int64: (maxConfidence: UInt8, sumX: Float, sumY: Float, sumZ: Float, count: Int)] = [:]
            for point in points {
                guard point.confidence >= Self.minConfidence else { continue }
                let key = Self.cellKey(worldX: point.worldX, worldZ: point.worldZ)
                var bucket = frameBuckets[key] ?? (0, 0, 0, 0, 0)
                bucket.maxConfidence = max(bucket.maxConfidence, point.confidence)
                bucket.sumX += point.worldX
                bucket.sumY += point.worldY
                bucket.sumZ += point.worldZ
                bucket.count += 1
                frameBuckets[key] = bucket
            }

            for (key, bucket) in frameBuckets {
                var cell = cells[key] ?? Cell()
                // 동일 timestamp 재유입은 무시 (독립 프레임만 누적).
                if cell.lastTimestamp == timestamp, cell.hitCount > 0 {
                    continue
                }
                let wasStable = Int(cell.hitCount) >= Self.observationsForStable
                cell.hitCount = cell.hitCount &+ 1
                if cell.hitCount == 0 { cell.hitCount = UInt16.max }
                cell.lastTimestamp = timestamp
                cell.maxConfidence = max(cell.maxConfidence, bucket.maxConfidence)
                let inv = 1 / Float(max(bucket.count, 1))
                cell.lastX = bucket.sumX * inv
                cell.lastY = bucket.sumY * inv
                cell.lastZ = bucket.sumZ * inv
                cells[key] = cell
                if !wasStable, Int(cell.hitCount) >= Self.observationsForStable {
                    newlyStable += 1
                }

                let meanX = cell.lastX
                let meanY = cell.lastY
                let meanZ = cell.lastZ
                let dx = meanX - cameraPosition.x
                let dy = meanY - cameraPosition.y
                let dz = meanZ - cameraPosition.z
                let d = sqrt(dx * dx + dy * dy + dz * dz)
                if d.isFinite {
                    depthSum += d
                    depthCount += 1
                }
            }

            if cells.count > Self.maxCells {
                pruneOldest(keeping: Self.maxCells * 3 / 4)
            }
        }

        let meanDepth = depthCount > 0 ? depthSum / Float(depthCount) : 0
        let quality = Self.evaluateQuality(
            trackingLimited: trackingLimited,
            speed: speed,
            meanDepth: meanDepth,
            hasSamples: depthCount > 0
        )

        var stableKeys = Set<Int64>()
        var tentativeKeys = Set<Int64>()
        var cellHeights: [Int64: Float] = [:]
        var cellCenters: [Int64: SIMD2<Float>] = [:]
        stableKeys.reserveCapacity(cells.count)
        tentativeKeys.reserveCapacity(cells.count / 2)
        cellHeights.reserveCapacity(cells.count)
        cellCenters.reserveCapacity(cells.count)
        for (key, cell) in cells {
            cellHeights[key] = cell.lastY
            cellCenters[key] = SIMD2(cell.lastX, cell.lastZ)
            if Int(cell.hitCount) >= Self.observationsForStable {
                stableKeys.insert(key)
            } else if cell.hitCount > 0 {
                tentativeKeys.insert(key)
            }
        }

        return ScanCoverageSnapshot(
            observedCellCount: cells.count,
            stableCellCount: stableKeys.count,
            tentativeCellCount: tentativeKeys.count,
            newlyStabilizedCount: newlyStable,
            quality: quality,
            meanDepthMeters: meanDepth,
            cameraSpeedMetersPerSecond: speed,
            stableKeys: stableKeys,
            tentativeKeys: tentativeKeys,
            cellHeights: cellHeights,
            cellCenters: cellCenters
        )
    }

    public static func evaluateQuality(
        trackingLimited: Bool,
        speed: Float,
        meanDepth: Float,
        hasSamples: Bool
    ) -> ScanCoverageQuality {
        if trackingLimited { return .trackingBad }
        if speed > tooFastMetersPerSecond { return .tooFast }
        if hasSamples {
            if meanDepth > 0, meanDepth < tooCloseMeters { return .tooClose }
            if meanDepth > tooFarMeters { return .tooFar }
        }
        return .normal
    }

    private func pruneOldest(keeping: Int) {
        guard cells.count > keeping else { return }
        let sorted = cells.sorted { $0.value.lastTimestamp < $1.value.lastTimestamp }
        let removeCount = cells.count - keeping
        for i in 0..<removeCount {
            cells.removeValue(forKey: sorted[i].key)
        }
    }
}
