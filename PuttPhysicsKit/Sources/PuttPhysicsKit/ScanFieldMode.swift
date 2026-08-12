import Foundation

/// 스캔·높이맵 복도 프리셋. 앱 `ScanFieldSettings`와 연동.
public enum ScanFieldMode: String, CaseIterable, Sendable, Codable, Identifiable {
    /// 편도 스캔 — 실제 경기. LiDAR FOV로 홀 뒤 ~1m까지 높이맵 포함.
    case competition
    /// 왕복 스캔·알고리즘 검증용(기본).
    case tuning

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .competition: return "경기"
        case .tuning: return "튜닝"
        }
    }
}

public struct ScanCorridorMargins: Sendable, Equatable {
    public var lateralHalfWidth: Double
    public var ballEndMargin: Double
    public var pastHoleMargin: Double
    public var displayHalfWidth: Double
    public var displayPastHoleMargin: Double

    public init(
        lateralHalfWidth: Double,
        ballEndMargin: Double,
        pastHoleMargin: Double,
        displayHalfWidth: Double,
        displayPastHoleMargin: Double
    ) {
        self.lateralHalfWidth = lateralHalfWidth
        self.ballEndMargin = ballEndMargin
        self.pastHoleMargin = pastHoleMargin
        self.displayHalfWidth = displayHalfWidth
        self.displayPastHoleMargin = displayPastHoleMargin
    }
}
