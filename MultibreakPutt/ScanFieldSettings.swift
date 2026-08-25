import Foundation
import PuttPhysicsKit

/// 경기 / 튜닝 스캔 복도 프리셋 — UserDefaults.
enum ScanFieldSettings {
    static let fieldModeKey = "scan.fieldMode"
    static let didChangeNotification = Notification.Name("ScanFieldSettings.didChange")

    static var fieldMode: ScanFieldMode {
        if let raw = UserDefaults.standard.string(forKey: fieldModeKey),
           let mode = ScanFieldMode(rawValue: raw) {
            return mode
        }
        return .tuning
    }

    static var corridorMargins: ScanCorridorMargins {
        PuttScanCorridor.margins(for: fieldMode)
    }

    static func notifyDidChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

extension ScanFieldMode {
    var settingsDetail: String {
        switch self {
        case .competition:
            return "편도 · 볼 지정 후 사선(~30°)으로 홀까지 걷기 → 홀 지정 직후 계산. 복도 6m."
        case .tuning:
            return "왕복 검증용(기본). 사선(~30°)으로 홀까지 걷기 · 복도 6m."
        }
    }
}
