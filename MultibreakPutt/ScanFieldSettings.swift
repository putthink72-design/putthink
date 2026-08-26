import Foundation
import PuttPhysicsKit

/// 지정 계산 모드 · 복도 프리셋 — UserDefaults.
enum ScanFieldSettings {
    static let fieldModeKey = "scan.fieldMode"
    static let didChangeNotification = Notification.Name("ScanFieldSettings.didChange")

    static var fieldMode: ScanFieldMode {
        if let raw = UserDefaults.standard.string(forKey: fieldModeKey),
           let mode = ScanFieldMode(rawValue: raw) {
            return mode
        }
        return .competition
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
            return "홀 지정 직후 경로를 계산·표시합니다. 돌아와 실볼이 그대로일 때 사용하세요."
        case .tuning:
            return "홀 지정 직후 경로를 계산한 뒤, 볼로 돌아가 실제 볼 위치를 다시 지정합니다."
        }
    }

    var pathMode: ScanPathMode {
        switch self {
        case .competition: return .oneWay
        case .tuning: return .roundTrip
        }
    }
}

extension ScanPathMode {
    var fieldMode: ScanFieldMode {
        switch self {
        case .oneWay: return .competition
        case .roundTrip: return .tuning
        }
    }
}
