import Foundation
import SwiftUI

/// Local free-run ledger until Supabase Edge Functions are live.
/// Spec: organic 3 / invited 6; claim once per device; deduct after guidance readout.
@MainActor
final class FreeRunsStore: ObservableObject {
    static let organicGrant = 3
    static let invitedGrant = 6

    private static let claimedKey = "putthink.freeTier.claimed"
    private static let balanceKey = "putthink.freeTier.balance"
    private static let sourceKey = "putthink.freeTier.source"
    private static let pendingInviteKey = "putthink.freeTier.pendingInviteCode"
    private static let serverAuthoritativeKey = "putthink.freeTier.serverAuthoritative"

    enum Source: String {
        case organic
        case invited
    }

    enum ClipboardInviteResult {
        case applied(code: String)
        case notFound
        case unavailable
    }

    @Published private(set) var balance: Int = 0
    @Published private(set) var hasClaimed = false
    @Published private(set) var source: Source = .organic

    /// When true, local balance is a cache of server `profiles.free_runs_balance`.
    @Published private(set) var serverAuthoritative = false

    var deviceClaimToken: String { DeviceKeychain.deviceClaimToken() }
    var deviceKeychainID: String { deviceClaimToken }

    var pendingInviteCode: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: Self.pendingInviteKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        set {
            if let newValue, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.pendingInviteKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pendingInviteKey)
            }
        }
    }

    init() {
        serverAuthoritative = UserDefaults.standard.bool(forKey: Self.serverAuthoritativeKey)
        hasClaimed = UserDefaults.standard.bool(forKey: Self.claimedKey)
        if let raw = UserDefaults.standard.string(forKey: Self.sourceKey),
           let parsed = Source(rawValue: raw) {
            source = parsed
        }
        if hasClaimed {
            balance = max(0, UserDefaults.standard.integer(forKey: Self.balanceKey))
        } else {
            claimLocalIfNeeded()
        }
    }

    /// User-initiated: Settings → free runs → apply from clipboard (may show iOS paste permission).
    @discardableResult
    func applyClipboardInviteIfPresent() -> ClipboardInviteResult {
        guard canAcceptInviteUpgrade else { return .unavailable }
        guard let code = InviteDeepLink.codeFromClipboardIfPresent() else {
            return .notFound
        }
        rememberInviteCode(code)
        return .applied(code: code)
    }

    /// Universal Link / pending code can still upgrade unused organic grant.
    var canAcceptInviteUpgrade: Bool {
        if source == .invited { return false }
        if serverAuthoritative { return false }
        if !hasClaimed { return true }
        return source == .organic && balance == Self.organicGrant
    }

    /// First launch on this device: grant 3 (or 6 if invite pending before claim).
    func claimLocalIfNeeded() {
        guard !hasClaimed else { return }
        let invited = pendingInviteCode != nil
        source = invited ? .invited : .organic
        balance = invited ? Self.invitedGrant : Self.organicGrant
        hasClaimed = true
        persist()
    }

    /// Store invite from Universal Link / clipboard. Upgrades unused organic→invited before server claim.
    func rememberInviteCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingInviteCode = trimmed
        if !hasClaimed {
            claimLocalIfNeeded()
            return
        }
        guard !serverAuthoritative,
              source == .organic,
              balance == Self.organicGrant
        else { return }
        source = .invited
        balance = Self.invitedGrant
        persist()
    }

    /// Push local grant + invite code to `claim-free-tier` once per device/account.
    func syncClaimWithServer(auth: AuthSessionStore) async {
        guard !serverAuthoritative, PutthinkSupabaseConfig.isConfigured else { return }
        do {
            try await auth.ensureSupabaseSessionForUpload()
            guard let token = auth.supabaseAccessToken else { return }
            let result = try await InviteAPI.claimFreeTier(
                accessToken: token,
                deviceClaimToken: deviceClaimToken,
                inviteCode: pendingInviteCode,
                localBalance: balance
            )
            if result.source == "invited" {
                source = .invited
            } else if source != .invited {
                source = .organic
            }
            applyServerBalance(result.balance, replaceLocal: true)
            pendingInviteCode = nil
        } catch {
            // Keep local ledger; retry on next launch / auth.
        }
    }

    func canConsumeRun(isSubscribed: Bool) -> Bool {
        if SubscriptionStore.temporarilyUnlockScanStart { return true }
        if isSubscribed { return true }
        return balance > 0
    }

    /// Call when Gate 5.5 readout shows valid distance/angle (successful guidance).
    @discardableResult
    func consumeAfterGuidanceReady(isSubscribed: Bool) -> Bool {
        if SubscriptionStore.temporarilyUnlockScanStart { return true }
        if isSubscribed { return true }
        guard balance > 0 else { return false }
        balance -= 1
        persist()
        if serverAuthoritative {
            Task {
                await Self.pushConsumeToServer(isSubscribed: false)
            }
        }
        return true
    }

    private static func pushConsumeToServer(isSubscribed: Bool) async {
        // Best-effort; local balance already deducted.
        guard PutthinkSupabaseConfig.isConfigured,
              let base = URL(string: PutthinkSupabaseConfig.urlString)
        else { return }
        do {
            let session = try await SupabaseAuthAPI.ensureDeviceSession()
            let url = base
                .appendingPathComponent("functions")
                .appendingPathComponent("v1")
                .appendingPathComponent(PutthinkSupabaseConfig.consumeFreeRunPath)
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(PutthinkSupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "is_subscribed": isSubscribed,
            ])
            _ = try await URLSession.shared.data(for: req)
        } catch {
            // Keep local ledger; next claim/sync can reconcile.
        }
    }

    /// First login: copy remaining device balance to server profile (Edge Function).
    /// Returning login: trust server and discard local.
    func applyServerBalance(_ serverBalance: Int, replaceLocal: Bool) {
        if replaceLocal || !serverAuthoritative {
            balance = max(0, serverBalance)
        }
        serverAuthoritative = true
        hasClaimed = true
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(hasClaimed, forKey: Self.claimedKey)
        UserDefaults.standard.set(balance, forKey: Self.balanceKey)
        UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
        UserDefaults.standard.set(serverAuthoritative, forKey: Self.serverAuthoritativeKey)
    }
}
