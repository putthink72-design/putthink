import Foundation

/// 사용자 그린스피드(Stimpmeter 상당, m). 설정 슬라이더와 조준 물리 엔진이 공유.
enum GreenSpeedSettings {
    static let storageKey = "perf.greenSpeed"
    static let minimum = 2.0
    static let maximum = 3.2
    static let step = 0.1
    static let defaultMeters = 2.5

    static func clamped(_ value: Double) -> Double {
        let limited = min(max(value, minimum), maximum)
        return (limited * 10).rounded() / 10
    }

    static func load() -> Double {
        let stored = UserDefaults.standard.object(forKey: storageKey) as? Double
        return clamped(stored ?? defaultMeters)
    }

    static func save(_ value: Double) {
        UserDefaults.standard.set(clamped(value), forKey: storageKey)
    }

    /// 표시 라벨. 경계: &lt;2.1 느림 · ≤2.7 보통 · ≤2.9 약간빠름 · ≤3.1 빠름 · 3.2 매우빠름.
    static func label(for meters: Double) -> String {
        let v = clamped(meters)
        if v < 2.1 { return L10n.settingsGreenSpeedSlow }
        if v <= 2.7 { return L10n.settingsGreenSpeedNormal }
        if v <= 2.9 { return L10n.settingsGreenSpeedSlightlyFast }
        if v <= 3.1 { return L10n.settingsGreenSpeedFast }
        return L10n.settingsGreenSpeedVeryFast
    }
}
