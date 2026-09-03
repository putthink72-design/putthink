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
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let preferenceKey = "scanpar.appLanguage"

    @Published private(set) var option: AppLanguageOption

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.preferenceKey),
           let stored = AppLanguageOption(rawValue: raw) {
            option = stored
        } else {
            option = .system
        }
    }

    /// Must run in `App.init` before the first localized string is resolved.
    static func applyPersistedLanguageAtLaunch() {
        let raw = UserDefaults.standard.string(forKey: preferenceKey)
        let option = raw.flatMap(AppLanguageOption.init(rawValue:)) ?? .system
        applyAppleLanguages(option)
    }

    func select(_ option: AppLanguageOption) {
        self.option = option
        UserDefaults.standard.set(option.rawValue, forKey: Self.preferenceKey)
        Self.applyAppleLanguages(option)
    }

    private static func applyAppleLanguages(_ option: AppLanguageOption) {
        if let code = option.appleLanguageCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}
