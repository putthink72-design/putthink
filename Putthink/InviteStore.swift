import AuthenticationServices
import Foundation
import SwiftUI
import UIKit

@MainActor
final class InviteStore: ObservableObject {
    @Published var inviteURL: URL?
    @Published var inviteCode: String?
    @Published var statusMessage: String?
    @Published var isBusy = false
    @Published var showInviteShare = false
    @Published var showPostUploadInvite = false

    func shareMessage(for locale: Locale) -> String {
        let link = inviteURL?.absoluteString ?? "https://putthink.com"
        let lang = locale.language.languageCode?.identifier ?? "en"
        switch lang {
        case "ko":
            return "친구야, 나 요즘 이 앱으로 퍼팅 연습해 — 이 링크로 깔면 무료로 6번 더 써볼 수 있어 👉 \(link)"
        case "ja":
            return "最近このアプリでグリーンを読んでる。このリンクから入れると無料で6回多く使えるよ 👉 \(link)"
        default:
            return "Been using this app to read greens — install via my link and get 6 free tries 👉 \(link)"
        }
    }

    /// Requires a real Apple → Supabase session (not device-email).
    func ensureCodeAndShare(auth: AuthSessionStore) async {
        statusMessage = nil
        isBusy = true
        defer { isBusy = false }

        do {
            try await auth.ensureAppleSupabaseSession()
            guard let token = auth.supabaseAccessToken else {
                statusMessage = L10n.inviteNeedApple
                return
            }
            let result = try await InviteAPI.ensureInviteCode(accessToken: token)
            inviteCode = result.code
            inviteURL = URL(string: result.url)
            showInviteShare = true
        } catch let err as AuthSessionError {
            switch err {
            case .appleCanceled:
                break
            case .missingIdentityToken:
                statusMessage = L10n.inviteNeedApple
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

enum InviteAPI {
    struct EnsureResult: Sendable {
        var code: String
        var url: String
    }

    static func ensureInviteCode(accessToken: String) async throws -> EnsureResult {
        guard PutthinkSupabaseConfig.isConfigured,
              let base = URL(string: PutthinkSupabaseConfig.urlString)
        else { throw ShowcaseUploadError.notConfigured }

        let url = base
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("ensure-invite-code")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(PutthinkSupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inviteCode = json["code"] as? String,
              let inviteURL = json["url"] as? String
        else {
            let body = String(data: data, encoding: .utf8) ?? "ensure-invite-code \(code)"
            throw ShowcaseUploadError.http(code, body)
        }
        return EnsureResult(code: inviteCode, url: inviteURL)
    }

    static func claimFreeTier(
        accessToken: String,
        deviceClaimToken: String,
        inviteCode: String?,
        localBalance: Int
    ) async throws -> (balance: Int, source: String, alreadyClaimed: Bool) {
        guard PutthinkSupabaseConfig.isConfigured,
              let base = URL(string: PutthinkSupabaseConfig.urlString)
        else { throw ShowcaseUploadError.notConfigured }

        let url = base
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent(PutthinkSupabaseConfig.claimFreeTierPath)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(PutthinkSupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "device_claim_token": deviceClaimToken,
            "local_balance": localBalance,
        ]
        if let inviteCode, !inviteCode.isEmpty {
            payload["invite_code"] = inviteCode
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let balance = json["free_runs_balance"] as? Int
        else {
            let body = String(data: data, encoding: .utf8) ?? "claim-free-tier \(status)"
            throw ShowcaseUploadError.http(status, body)
        }
        let source = (json["free_tier_source"] as? String) ?? "organic"
        let already = (json["already_claimed"] as? Bool) ?? false
        return (balance, source, already)
    }
}

/// UIKit share sheet wrapper.
struct ActivityShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    var onComplete: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
