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
            return "편도 스캔 · 홀 지정 직후 계산. 볼 뒤 0.5m·홀 뒤 ~1m까지 높이맵에 포함됩니다."
        case .tuning:
            return "왕복 스캔·알고리즘 검증용(기본). 볼 뒤 0.5m·홀 뒤 ~1m."
        }
    }
}
