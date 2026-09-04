import Foundation

/// 스캔·높이맵 복도 프리셋. 앱 `ScanFieldSettings`와 연동.
public enum ScanFieldMode: String, CaseIterable, Sendable, Codable, Identifiable {
    /// 볼홀지정계산 — 홀 지정 직후 경로 표시. 조준 중 실볼 자동 정렬.
    case competition
    /// 볼홀볼지정계산 — 홀 지정 직후 계산. 돌아와 조준하면 실볼 자동 정렬.
    case tuning

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .competition: return "볼홀지정계산"
        case .tuning: return "볼홀볼지정계산"
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
