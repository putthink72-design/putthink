import Foundation
import Security

/// Reinstall-stable device claim token in Keychain (`device_claim_token`).
enum DeviceKeychain {
    private static let service = "com.putthink.putthink.device"
    private static let account = "device_claim_token"
    private static let legacyAccount = "device_keychain_id"

    /// UUID string used as `profiles.device_claim_token`.
    static func deviceClaimToken() -> String {
        if let existing = read(account: account) { return existing }
        if let legacy = read(account: legacyAccount) {
            save(account: account, value: legacy)
            return legacy
        }
        let created = UUID().uuidString.lowercased()
        save(account: account, value: created)
        return created
    }

    /// - Warning: Deprecated name — use `deviceClaimToken()`.
    static func deviceKeychainID() -> String { deviceClaimToken() }

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
}
