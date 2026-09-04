import Foundation
import simd

/// 스캔 중 발·다리·깃대처럼 지면에서 갑자기 솟은 돌출을 제거한다.
/// 그린은 ‘작고 가파른 언덕’이 없다는 가정 — 국소 상승 + 작은 blob / 좁은 수직 기둥만 버림.
/// depth 융합·최종 지형에만 사용. 메시 시각화/준비 카운트에는 적용하지 말 것.
enum GroundScanFilter {
    /// 레거시 근접 필터: 카메라 근처에서 지면(하위 사분위)보다 이만큼 높으면 발 후보.
    static let nearRiseMeters = 0.05
    /// 발 후보로 볼 수평 거리 (카메라 XZ 기준).
    static let nearRadiusMeters = 1.6
    /// 볼 고도 대비 절대 상한 (장거리 언듈레이션 여유 포함).
    static let absoluteAboveBallMeters = 0.22

    /// 국소 지면(주변 셀 p30) 대비 이만큼 높으면 돌출 후보.
    static let localRiseMeters = 0.045
    /// 돌출 blob 최대 지름(m). 이보다 작으면 발·다리로 제거.
    static let maxFootBlobDiameterMeters = 0.55
    /// blob 내 최대 상승이 이 값 미만이면 노이즈로 보고 유지(완만한 기복 보호).
    static let minBlobPeakRiseMeters = 0.06
    /// 공간 해시 셀 크기.
    static let gridCellMeters = 0.16

    /// 깃대·기둥 등 좁은 수직 돌출 — 지면 대비 세로가 footprint보다 훨씬 큼.
    static let minVerticalPoleSpanMeters = 0.25
    /// 수직 기둥으로 볼 XZ footprint 상한(m). 그린 언듈레이션 폭보다 좁게.
    static let maxVerticalPoleFootprintMeters = 0.48
    /// span/footprint 비율. 좁지 않아도 세로로 길면(깃발 포함) 제거.
    static let minVerticalPoleAspectRatio = 2.0
    /// 수직 기둥 판정용 XZ 셀(m).
    static let verticalColumnCellMeters = 0.10
    /// 기둥 제거 시 지면 위 이 높이까지는 유지(잔디 접촉면).
    static let poleGroundMarginMeters = 0.05

    struct Point {
        var worldX: Double
        var worldY: Double
        var worldZ: Double
    }

    /// 계산용 지형 포인트 일괄 정제: 국소 spike/blob → (옵션) 카메라 근접 → (옵션) 볼 상한.
    static func cleanTerrainPoints(
        _ points: [Point],
        cameraX: Double? = nil,
        cameraY: Double? = nil,
        cameraZ: Double? = nil,
        ballY: Double? = nil
    ) -> [Point] {
        let featureMask = combinedFeatureRejectionMask(points)
        var cleaned: [Point] = []
        cleaned.reserveCapacity(points.count)
        for (index, point) in points.enumerated() where !featureMask[index] {
            cleaned.append(point)
        }
        if let cameraX, let cameraY, let cameraZ {
            cleaned = rejectNearProtrusions(
                points: cleaned,
                cameraX: cameraX,
                cameraY: cameraY,
                cameraZ: cameraZ
            )
        }
        if let ballY {
            cleaned = rejectAboveBallReference(points: cleaned, ballY: ballY)
        }
        return cleaned
    }

    /// 프레임 단위: 근처+솟음 제거. 먼 그린 언듈레이션은 유지.
    static func rejectNearProtrusions(
        points: [Point],
        cameraX: Double,
        cameraY: Double,
        cameraZ: Double
    ) -> [Point] {
        guard points.count >= 8 else { return points }
        _ = cameraY
        let heights = points.map(\.worldY).sorted()
        let ground = percentile(heights, 0.25)
        let radius = nearRadiusMeters * 0.65
        return points.filter { point in
            let horiz = hypot(point.worldX - cameraX, point.worldZ - cameraZ)
            if horiz <= radius, point.worldY > ground + nearRiseMeters {
                return false
            }
            return true
        }
    }

    /// 볼이 지정된 뒤: 볼 지면보다 과도하게 높은 점 제거.
    static func rejectAboveBallReference(
        points: [Point],
        ballY: Double
    ) -> [Point] {
        let ceiling = ballY + absoluteAboveBallMeters
        return points.filter { $0.worldY <= ceiling }
    }

    /// 국소 돌출 + 작은 blob 제거.
    /// - 주변 셀 지면보다 `localRiseMeters` 이상 높은 점을 표시
    /// - 연결된 돌출 덩어리 지름이 `maxFootBlobDiameterMeters` 이하이고
    ///   피크 상승 ≥ `minBlobPeakRiseMeters`이면 발/다리로 버림
    static func rejectFootLikeSpikes(_ points: [Point]) -> [Point] {
        let reject = footRejectionMask(points)
        guard reject.contains(true) else { return points }
        var kept: [Point] = []
        kept.reserveCapacity(points.count)
        for (index, point) in points.enumerated() where !reject[index] {
            kept.append(point)
        }
        return kept
    }

    /// `true` = 제거할 발·다리 후보.
    static func footRejectionMask(_ points: [Point]) -> [Bool] {
        let count = points.count
        var reject = [Bool](repeating: false, count: count)
        guard count >= 24 else { return reject }

        let cell = gridCellMeters
        var cellHeights: [CellKey: [Double]] = [:]
        cellHeights.reserveCapacity(min(count, 4_096))
        var cellOfPoint = [CellKey](repeating: CellKey(x: 0, z: 0), count: count)

        for (index, point) in points.enumerated() {
            let key = CellKey(
                x: Int(floor(point.worldX / cell)),
                z: Int(floor(point.worldZ / cell))
            )
            cellOfPoint[index] = key
            cellHeights[key, default: []].append(point.worldY)
        }

        var cellGround: [CellKey: Double] = [:]
        cellGround.reserveCapacity(cellHeights.count)
        for (key, heights) in cellHeights {
            cellGround[key] = percentile(heights.sorted(), 0.30)
        }

        func localGround(for key: CellKey) -> Double {
            var gathered: [Double] = []
            gathered.reserveCapacity(9)
            for dz in -1...1 {
                for dx in -1...1 {
                    let neighbor = CellKey(x: key.x + dx, z: key.z + dz)
                    if let g = cellGround[neighbor] {
                        gathered.append(g)
                    }
                }
            }
            guard !gathered.isEmpty else {
                return cellGround[key] ?? 0
            }
            return percentile(gathered.sorted(), 0.30)
        }

        var rise = [Double](repeating: 0, count: count)
        var elevatedIndices: [Int] = []
        elevatedIndices.reserveCapacity(count / 8)

        for index in 0..<count {
            let ground = localGround(for: cellOfPoint[index])
            let r = points[index].worldY - ground
            rise[index] = r
            if r > localRiseMeters {
                elevatedIndices.append(index)
            }
        }

        guard !elevatedIndices.isEmpty else { return reject }

        var parent = Array(0..<count)
        func find(_ i: Int) -> Int {
            var x = i
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        var elevatedByCell: [CellKey: [Int]] = [:]
        for index in elevatedIndices {
            elevatedByCell[cellOfPoint[index], default: []].append(index)
        }

        for index in elevatedIndices {
            let key = cellOfPoint[index]
            for dz in -1...1 {
                for dx in -1...1 {
                    let neighborKey = CellKey(x: key.x + dx, z: key.z + dz)
                    guard let neighbors = elevatedByCell[neighborKey] else { continue }
                    for other in neighbors where other > index {
                        let dxw = points[index].worldX - points[other].worldX
                        let dzw = points[index].worldZ - points[other].worldZ
                        if (dxw * dxw + dzw * dzw) <= (cell * cell * 2.25) {
                            union(index, other)
                        }
                    }
                }
            }
        }

        var clusterMembers: [Int: [Int]] = [:]
        for index in elevatedIndices {
            clusterMembers[find(index), default: []].append(index)
        }

        let maxDiameterSq = maxFootBlobDiameterMeters * maxFootBlobDiameterMeters
        for members in clusterMembers.values {
            var minX = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude
            var minZ = Double.greatestFiniteMagnitude
            var maxZ = -Double.greatestFiniteMagnitude
            var peakRise = 0.0
            for index in members {
                let p = points[index]
                minX = min(minX, p.worldX)
                maxX = max(maxX, p.worldX)
                minZ = min(minZ, p.worldZ)
                maxZ = max(maxZ, p.worldZ)
                peakRise = max(peakRise, rise[index])
            }
            let dx = maxX - minX
            let dz = maxZ - minZ
            let diameterSq = dx * dx + dz * dz
            let isSmallBlob = diameterSq <= maxDiameterSq
            if isSmallBlob, peakRise >= minBlobPeakRiseMeters {
                for index in members { reject[index] = true }
            } else if members.count <= 3, peakRise >= localRiseMeters {
                for index in members { reject[index] = true }
            }
        }
        return reject
    }

    /// 발·다리 + 수직 기둥(깃대) 제거 마스크.
    static func combinedFeatureRejectionMask(_ points: [Point]) -> [Bool] {
        let foot = footRejectionMask(points)
        let pole = verticalPoleRejectionMask(points)
        guard foot.contains(true) || pole.contains(true) else {
            return foot
        }
        var combined = foot
        for index in 0..<points.count where pole[index] {
            combined[index] = true
        }
        return combined
    }

    /// 깃대·좁은 기둥 mesh — 국소 지면 위로 길게 솟은 좁은 XZ footprint 제거.
    static func rejectVerticalPoleLikeProtrusions(_ points: [Point]) -> [Point] {
        let reject = verticalPoleRejectionMask(points)
        guard reject.contains(true) else { return points }
        var kept: [Point] = []
        kept.reserveCapacity(points.count)
        for (index, point) in points.enumerated() where !reject[index] {
            kept.append(point)
        }
        return kept
    }

    /// `true` = 제거할 깃대·수직 기둥 후보.
    static func verticalPoleRejectionMask(_ points: [Point]) -> [Bool] {
        let count = points.count
        var reject = [Bool](repeating: false, count: count)
        guard count >= 12 else { return reject }

        let columnCell = verticalColumnCellMeters
        var columnIndices: [CellKey: [Int]] = [:]
        columnIndices.reserveCapacity(min(count, 2_048))
        var columnOfPoint = [CellKey](repeating: CellKey(x: 0, z: 0), count: count)

        for (index, point) in points.enumerated() {
            let key = CellKey(
                x: Int(floor(point.worldX / columnCell)),
                z: Int(floor(point.worldZ / columnCell))
            )
            columnOfPoint[index] = key
            columnIndices[key, default: []].append(index)
        }

        let groundCell = gridCellMeters
        var cellHeights: [CellKey: [Double]] = [:]
        for point in points {
            let key = CellKey(
                x: Int(floor(point.worldX / groundCell)),
                z: Int(floor(point.worldZ / groundCell))
            )
            cellHeights[key, default: []].append(point.worldY)
        }
        var cellGround: [CellKey: Double] = [:]
        for (key, heights) in cellHeights {
            cellGround[key] = percentile(heights.sorted(), 0.30)
        }

        func localGround(at point: Point) -> Double {
            let gx = Int(floor(point.worldX / groundCell))
            let gz = Int(floor(point.worldZ / groundCell))
            var gathered: [Double] = []
            gathered.reserveCapacity(9)
            for dz in -1...1 {
                for dx in -1...1 {
                    let neighbor = CellKey(x: gx + dx, z: gz + dz)
                    if let g = cellGround[neighbor] {
                        gathered.append(g)
                    }
                }
            }
            guard !gathered.isEmpty else { return point.worldY }
            return percentile(gathered.sorted(), 0.30)
        }

        var poleColumns: Set<CellKey> = []
        for (key, members) in columnIndices {
            guard members.count >= 2 else { continue }
            var localGroundY = Double.greatestFiniteMagnitude
            for index in members {
                localGroundY = min(localGroundY, localGround(at: points[index]))
            }
            var elevated: [Int] = []
            elevated.reserveCapacity(members.count)
            for index in members where points[index].worldY > localGroundY + poleGroundMarginMeters {
                elevated.append(index)
            }
            guard elevated.count >= 2 else { continue }

            var minX = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude
            var minZ = Double.greatestFiniteMagnitude
            var maxZ = -Double.greatestFiniteMagnitude
            var maxY = -Double.greatestFiniteMagnitude
            for index in elevated {
                let p = points[index]
                minX = min(minX, p.worldX)
                maxX = max(maxX, p.worldX)
                minZ = min(minZ, p.worldZ)
                maxZ = max(maxZ, p.worldZ)
                maxY = max(maxY, p.worldY)
            }
            let footprint = max(maxX - minX, maxZ - minZ)
            let verticalSpan = maxY - localGroundY
            let aspect = verticalSpan / max(footprint, columnCell * 0.5)
            let narrowFootprint = footprint <= maxVerticalPoleFootprintMeters
            let tallEnough = verticalSpan >= minVerticalPoleSpanMeters
            let poleLike = tallEnough && (narrowFootprint || aspect >= minVerticalPoleAspectRatio)
            if poleLike {
                poleColumns.insert(key)
            }
        }

        guard !poleColumns.isEmpty else { return reject }

        // 인접 기둥 셀 병합 — 깃대 mesh가 여러 column에 쪼개진 경우
        let flagged = poleColumns
        var expanded = flagged
        var changed = true
        while changed {
            changed = false
            for key in expanded {
                for dz in -1...1 {
                    for dx in -1...1 where dx != 0 || dz != 0 {
                        let neighbor = CellKey(x: key.x + dx, z: key.z + dz)
                        if flagged.contains(neighbor), !expanded.contains(neighbor) {
                            expanded.insert(neighbor)
                            changed = true
                        }
                    }
                }
            }
        }

        for index in 0..<count {
            let key = columnOfPoint[index]
            guard expanded.contains(key) else { continue }
            let ground = localGround(at: points[index])
            if points[index].worldY > ground + poleGroundMarginMeters {
                reject[index] = true
            }
        }
        return reject
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let t = min(max(p, 0), 1)
        let index = Int(Double(sorted.count - 1) * t)
        return sorted[index]
    }

    private struct CellKey: Hashable {
        var x: Int
        var z: Int
    }
}
