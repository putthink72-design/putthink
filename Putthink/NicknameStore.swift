import Foundation
import Security

/// Device-scoped display nickname (Keychain). Created on first launch without user input.
@MainActor
final class NicknameStore: ObservableObject {
    @Published private(set) var nickname: String
    @Published private(set) var isCustom: Bool
    @Published var statusMessage: String?

    private var autoComponents: NicknameGenerator.Components?

    private static let service = "com.putthink.putthink.nickname"
    private static let accountValue = "display_nickname"
    private static let accountCustom = "display_nickname_custom"
    private static let accountModifier = "display_nickname_modifier"
    private static let accountNoun = "display_nickname_noun"
    private static let accountDigits = "display_nickname_digits"

    init() {
        if let saved = Self.read(account: Self.accountValue), !saved.isEmpty {
            nickname = saved
            isCustom = Self.read(account: Self.accountCustom) == "1"
            if !isCustom,
               let m = Self.read(account: Self.accountModifier),
               let n = Self.read(account: Self.accountNoun),
               let d = Self.read(account: Self.accountDigits) {
                autoComponents = NicknameGenerator.Components(modifier: m, noun: n, digits: d)
            }
        } else {
            let generated = NicknameGenerator.random()
            nickname = generated.value
            isCustom = false
            autoComponents = generated
            persist(generated, custom: false)
        }
    }

    /// Dice: new modifier + noun + digits.
    func regenerate() {
        let generated = NicknameGenerator.random()
        nickname = generated.value
        isCustom = false
        autoComponents = generated
        statusMessage = nil
        persist(generated, custom: false)
    }

    /// User-typed nickname (profanity filter required).
    @discardableResult
    func setCustom(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NicknameProfanityFilter.isAllowed(trimmed) else {
            statusMessage = L10n.nicknameRejected
            return false
        }
        guard trimmed.count <= 24 else {
            statusMessage = L10n.nicknameTooLong
            return false
        }
        nickname = trimmed
        isCustom = true
        autoComponents = nil
        statusMessage = nil
        Self.save(account: Self.accountValue, value: trimmed)
        Self.save(account: Self.accountCustom, value: "1")
        Self.delete(account: Self.accountModifier)
        Self.delete(account: Self.accountNoun)
        Self.delete(account: Self.accountDigits)
        return true
    }

    /// On unique conflict, redraw digits only (auto nicknames).
    func retryDigitsAfterCollision() -> String {
        if isCustom {
            return nickname
        }
        let base = autoComponents ?? NicknameGenerator.random()
        let next = NicknameGenerator.redrawDigits(keeping: base)
        autoComponents = next
        nickname = next.value
        persist(next, custom: false)
        return next.value
    }

    private func persist(_ components: NicknameGenerator.Components, custom: Bool) {
        Self.save(account: Self.accountValue, value: components.value)
        Self.save(account: Self.accountCustom, value: custom ? "1" : "0")
        Self.save(account: Self.accountModifier, value: components.modifier)
        Self.save(account: Self.accountNoun, value: components.noun)
        Self.save(account: Self.accountDigits, value: components.digits)
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func save(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
