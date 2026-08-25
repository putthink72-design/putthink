import Foundation

/// 볼→홀 퍼팅 라인에 직교한 복도.
/// 물리·융합·메시 필터가 동일 폭을 쓴다. 기종 보정은 복도 중심을 옮기지 않는다.
public enum PuttScanCorridor {
    /// 볼–홀 라인 기준 전체 폭.
    public static let orthogonalWidth = 6.0
    public static let orthogonalHalfWidth = orthogonalWidth / 2

    public static func margins(for mode: ScanFieldMode) -> ScanCorridorMargins {
        switch mode {
        case .competition:
            return ScanCorridorMargins(
                lateralHalfWidth: orthogonalHalfWidth,
                ballEndMargin: 0.5,
                pastHoleMargin: 1.0,
                displayHalfWidth: orthogonalHalfWidth,
                displayPastHoleMargin: 1.1
            )
        case .tuning:
            return ScanCorridorMargins(
                lateralHalfWidth: orthogonalHalfWidth,
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
