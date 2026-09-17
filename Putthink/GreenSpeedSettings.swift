import Foundation

/// 사용자 그린스피드(Stimpmeter 상당, m). 설정 슬라이더와 조준 물리 엔진이 공유.
enum GreenSpeedSettings {
    static let storageKey = "perf.greenSpeed"
    static let minimum = 2.0
    static let maximum = 4.0
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

    /// 표시 문장. 2.0–2.3 느림 · 2.4–2.7 보통 · 2.8–3.1 약간빠름 · 3.2–3.5 빠름 · 3.6–4.0 매우빠름.
    static func label(for meters: Double) -> String {
        let v = clamped(meters)
        if v <= 2.3 { return L10n.settingsGreenSpeedSlow }
        if v <= 2.7 { return L10n.settingsGreenSpeedNormal }
        if v <= 3.1 { return L10n.settingsGreenSpeedSlightlyFast }
        if v <= 3.5 { return L10n.settingsGreenSpeedFast }
        return L10n.settingsGreenSpeedVeryFast
    }
}
