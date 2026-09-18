import Foundation

enum AppLanguageOption: String, CaseIterable, Identifiable {
    case system
    case en
    case ko
    case ja

    var id: String { rawValue }

    var appleLanguageCode: String? {
        switch self {
        case .system: return nil
        case .en: return "en"
        case .ko: return "ko"
        case .ja: return "ja"
        }
    }

    var locale: Locale {
        if let code = appleLanguageCode {
            return Locale(identifier: code)
        }
        if let code = Locale.preferredLanguages.first {
            return Locale(identifier: code)
        }
        return .autoupdatingCurrent
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let preferenceKey = "putthink.appLanguage"

    @Published private(set) var option: AppLanguageOption
    /// OSD 등 시트 뒤 화면이 언어 변경을 즉시·닫힘 시 다시 읽도록 bump.
    @Published private(set) var displayEpoch: UInt = 0

    var locale: Locale { option.locale }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.preferenceKey),
           let stored = AppLanguageOption(rawValue: raw) {
            option = stored
        } else {
            option = .system
        }
        Self.applyAppleLanguages(option)
        L10n.locale = option.locale
    }

    /// Must run in `App.init` before the first localized string is resolved.
    static func applyPersistedLanguageAtLaunch() {
        let raw = UserDefaults.standard.string(forKey: preferenceKey)
        let option = raw.flatMap(AppLanguageOption.init(rawValue:)) ?? .system
        applyAppleLanguages(option)
        L10n.locale = option.locale
    }

    func select(_ option: AppLanguageOption) {
        guard option != self.option else { return }
        self.option = option
        UserDefaults.standard.set(option.rawValue, forKey: Self.preferenceKey)
        Self.applyAppleLanguages(option)
        L10n.locale = option.locale
        displayEpoch &+= 1
    }

    /// 설정 시트 닫힐 때 — 시트 표시 중 밀린 부모/OSD body를 한 번 더 돌린다.
    func refreshPresentedUI() {
        displayEpoch &+= 1
    }

    private static func applyAppleLanguages(_ option: AppLanguageOption) {
        if let code = option.appleLanguageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}
