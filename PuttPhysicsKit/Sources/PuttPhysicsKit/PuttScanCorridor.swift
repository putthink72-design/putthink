import Foundation

/// 볼→홀 퍼팅 라인 기준 lateral half-width (m).
/// 깊이 융합·메시 폴백·높이맵 export가 동일 값을 쓴다.
public enum PuttScanCorridor {
    public static func margins(for mode: ScanFieldMode) -> ScanCorridorMargins {
        switch mode {
        case .competition:
            return ScanCorridorMargins(
                lateralHalfWidth: 1.75,
                ballEndMargin: 0.5,
                pastHoleMargin: 1.0,
                displayHalfWidth: 3.0,
                displayPastHoleMargin: 1.1
            )
        case .tuning:
            return ScanCorridorMargins(
                lateralHalfWidth: 1.75,
                ballEndMargin: 0.5,
                pastHoleMargin: 1.0,
                displayHalfWidth: 3.0,
                displayPastHoleMargin: 1.1
            )
        }
    }

    /// 튜닝 모드와 동일 — 테스트·기본 인자용.
    public static var tuningMargins: ScanCorridorMargins {
        margins(for: .tuning)
    }

    public static var lateralHalfWidth: Double { tuningMargins.lateralHalfWidth }
    public static var displayHalfWidth: Double { tuningMargins.displayHalfWidth }
    public static var ballEndMargin: Double { tuningMargins.ballEndMargin }
    public static var pastHoleMargin: Double { tuningMargins.pastHoleMargin }
    public static var displayPastHoleMargin: Double { tuningMargins.displayPastHoleMargin }
}
