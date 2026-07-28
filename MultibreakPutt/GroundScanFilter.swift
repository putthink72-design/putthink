import Foundation
import simd

/// 스캔 중 발·다리처럼 지면에서 갑자기 솟은 근접 돌출을 제거한다.
/// 그린은 급격히 솟지 않는다는 가정 — LiDAR 해상도는 유지하고 이상 높이만 버림.
enum GroundScanFilter {
    /// 카메라 근처에서 지면(하위 사분위)보다 이만큼 높으면 발로 간주.
    static let nearRiseMeters = 0.07
    /// 발 후보로 볼 수평 거리 (카메라 XZ 기준).
    static let nearRadiusMeters = 1.45
    /// 볼 고도 대비 절대 상한 (장거리 언듈레이션 여유 포함). 발 필터의 주 수단은 nearRise.
    static let absoluteAboveBallMeters = 0.22

    struct Point {
        var worldX: Double
        var worldY: Double
        var worldZ: Double
    }

    /// 프레임 단위: 근처+솟음 제거. 먼 그린 언듈레이션은 유지.
    static func rejectNearProtrusions(
        points: [Point],
        cameraX: Double,
        cameraY: Double,
        cameraZ: Double
    ) -> [Point] {
        guard points.count >= 8 else { return points }
        let heights = points.map(\.worldY).sorted()
        let ground = percentile(heights, 0.25)
        return points.filter { point in
            let horiz = hypot(point.worldX - cameraX, point.worldZ - cameraZ)
            if horiz <= nearRadiusMeters,
               point.worldY > ground + nearRiseMeters {
                return false
            }
            // 카메라보다 확연히 높은 근접 점도(무릎·다리)
            if horiz <= nearRadiusMeters * 0.85,
               point.worldY > cameraY - 0.35 {
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

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let t = min(max(p, 0), 1)
        let index = Int(Double(sorted.count - 1) * t)
        return sorted[index]
    }
}
