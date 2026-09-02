import Foundation
import simd

/// 커버리지 바둑판을 AR 월드 원점 보정과 분리해 바닥에 고정하기 위한 표시 전용 유틸.
/// TerrainPipeline / 물리에는 쓰지 않는다.
public enum CoverageDisplayLock {
    public static let cellSizeMeters: Float = DisplaySurfaceGrid.cellSizeMeters
    public static let minCellsToPlant = 12

    public static func packedKey(ix: Int32, iz: Int32) -> Int64 {
        (Int64(ix) << 32) | Int64(UInt32(bitPattern: iz))
    }

    public static func unpack(_ key: Int64) -> (ix: Int32, iz: Int32) {
        (
            Int32(truncatingIfNeeded: key >> 32),
            Int32(bitPattern: UInt32(truncatingIfNeeded: key))
        )
    }

    public static func cellCenterXZ(_ key: Int64, cellSize: Float = cellSizeMeters) -> SIMD2<Float> {
        let (ix, iz) = unpack(key)
        return SIMD2((Float(ix) + 0.5) * cellSize, (Float(iz) + 0.5) * cellSize)
    }

    /// centroid가 속한 5cm 월드 격자 칸. 스틱 앵커를 여기에 맞춰야 로컬 메시가 월드 격자와 정합된다.
    public static func gridAnchorKey(
        for centroid: SIMD2<Float>,
        cellSize: Float = cellSizeMeters
    ) -> Int64 {
        let ix = Int32(floor(centroid.x / cellSize))
        let iz = Int32(floor(centroid.y / cellSize))
        return packedKey(ix: ix, iz: iz)
    }

    /// 월드 셀 → 앵커 기준 로컬 셀. stick 역변환 + floor 양자화는 최대 2.5cm 옆으로 밀린다.
    public static func localCellKey(worldKey: Int64, anchorKey: Int64) -> Int64 {
        let (wx, wz) = unpack(worldKey)
        let (ax, az) = unpack(anchorKey)
        return packedKey(ix: wx &- ax, iz: wz &- az)
    }

    /// 스틱이 `anchorKey` 격자 모서리에 있을 때 월드 셀 중심의 로컬 XZ.
    public static func localCellCenterXZ(
        worldKey: Int64,
        anchorKey: Int64,
        cellSize: Float = cellSizeMeters
    ) -> SIMD2<Float> {
        let localKey = localCellKey(worldKey: worldKey, anchorKey: anchorKey)
        let (lix, liz) = unpack(localKey)
        return SIMD2((Float(lix) + 0.5) * cellSize, (Float(liz) + 0.5) * cellSize)
    }

    /// 스틱이 `anchorKey` 격자 모서리에 있을 때의 월드 XZ.
    public static func stickCornerXZ(
        anchorKey: Int64,
        cellSize: Float = cellSizeMeters
    ) -> SIMD2<Float> {
        let (ax, az) = unpack(anchorKey)
        return SIMD2(Float(ax) * cellSize, Float(az) * cellSize)
    }

    public static func localCell(
        worldKey: Int64,
        anchorKey: Int64,
        lift: Float,
        existing: [Int64: DisplaySurfaceGrid.Cell],
        cellSize: Float = cellSizeMeters
    ) -> ResolvedCell {
        let localKey = localCellKey(worldKey: worldKey, anchorKey: anchorKey)
        if let cell = existing[localKey] {
            return ResolvedCell(key: localKey, cell: cell, created: false)
        }
        let (lix, liz) = unpack(localKey)
        let cell = DisplaySurfaceGrid.Cell(ix: lix, iz: liz, height: lift)
        return ResolvedCell(key: localKey, cell: cell, created: true)
    }

    public static func centroidXZ<S: Sequence>(
        of centers: S
    ) -> SIMD2<Float>? where S.Element == SIMD2<Float> {
        var sum = SIMD2<Float>(repeating: 0)
        var count: Float = 0
        for center in centers {
            sum += center
            count += 1
        }
        guard count > 0 else { return nil }
        return sum / count
    }

    public static func localKey(x: Float, z: Float, cellSize: Float = cellSizeMeters) -> Int64 {
        packedKey(
            ix: Int32(floor(x / cellSize)),
            iz: Int32(floor(z / cellSize))
        )
    }

    public struct ResolvedCell: Equatable, Sendable {
        public var key: Int64
        public var cell: DisplaySurfaceGrid.Cell
        public var created: Bool
    }

    /// 스틱 로컬 점을 5cm 칸으로만 자른다. 옆 칸에 붙이면 스캔한 칸이 구멍으로 남는다.
    public static func resolveLocalCell(
        localX: Float,
        localZ: Float,
        existing: [Int64: DisplaySurfaceGrid.Cell],
        lift: Float,
        cellSize: Float = cellSizeMeters
    ) -> ResolvedCell {
        let quantized = localKey(x: localX, z: localZ, cellSize: cellSize)
        if let cell = existing[quantized] {
            return ResolvedCell(key: quantized, cell: cell, created: false)
        }
        let (qix, qiz) = unpack(quantized)
        let cell = DisplaySurfaceGrid.Cell(ix: qix, iz: qiz, height: lift)
        return ResolvedCell(key: quantized, cell: cell, created: true)
    }
}

/// 스캔 직후 월드 원점이 아직 밀릴 때 바둑판을 그리지 않기 위한 XZ 안정 판정.
public struct CoverageOriginSettle: Equatable, Sendable {
    public var anchorCentroid: SIMD2<Float>?
    public var stableSince: TimeInterval?
    public let maxStepMeters: Float
    public let requiredDuration: TimeInterval

    public static let defaultMaxStepMeters: Float = 0.005
    public static let defaultRequiredDuration: TimeInterval = 0.55

    public init(
        maxStepMeters: Float = defaultMaxStepMeters,
        requiredDuration: TimeInterval = defaultRequiredDuration
    ) {
        self.maxStepMeters = maxStepMeters
        self.requiredDuration = requiredDuration
    }

    public init() {
        self.init(
            maxStepMeters: Self.defaultMaxStepMeters,
            requiredDuration: Self.defaultRequiredDuration
        )
    }

    /// 볼 지정 전 바닥 피드백용 — 짧게만 기다린다.
    public static let quickDisplay = CoverageOriginSettle(
        maxStepMeters: 0.012,
        requiredDuration: 0.12
    )

    public mutating func reset() {
        anchorCentroid = nil
        stableSince = nil
    }

    /// 첫 센트로이드에서 `maxStepMeters` 이내로 `requiredDuration` 초가 지나면 true.
    public mutating func observe(_ centroid: SIMD2<Float>?, now: TimeInterval) -> Bool {
        guard let centroid else {
            reset()
            return false
        }
        if let anchor = anchorCentroid, simd_distance(anchor, centroid) <= maxStepMeters {
            let start = stableSince ?? now
            stableSince = start
            return now - start >= requiredDuration
        }
        anchorCentroid = centroid
        stableSince = now
        return false
    }
}
