import AuthenticationServices
import Foundation
import SwiftUI
import UIKit

/// Sign in with Apple for invite (real Supabase user). Device session remains for Showcase upload Dev path.
@MainActor
final class AuthSessionStore: NSObject, ObservableObject {
    @Published private(set) var isSignedIn = false
    /// True when session is from Apple IdP (not device-email).
    @Published private(set) var isAppleLinked = false
    @Published private(set) var userID: String?
    @Published private(set) var supabaseAccessToken: String?
    @Published var statusMessage: String?
    @Published var isBusy = false

    private var currentController: ASAuthorizationController?
    private var appleContinuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    func signInWithApple() {
        Task {
            do {
                _ = try await ensureAppleSupabaseSession()
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func applySession(userID: String, accessToken: String, appleLinked: Bool) {
        self.userID = userID
        self.supabaseAccessToken = accessToken
        isSignedIn = true
        isAppleLinked = appleLinked
        statusMessage = nil
    }

    /// Device-bound Supabase email/password session for Showcase uploads.
    func ensureSupabaseSessionForUpload() async throws {
        if let token = supabaseAccessToken, userID != nil, !token.isEmpty, isAppleLinked {
            return
        }
        if let token = supabaseAccessToken, userID != nil, !token.isEmpty {
            return
        }
        let session = try await SupabaseAuthAPI.ensureDeviceSession()
        applySession(userID: session.userID, accessToken: session.accessToken, appleLinked: false)
    }

    /// Account deletion must hit the real cloud user — never mint a fresh device session if Apple was used.
    func ensureSessionForAccountDeletion() async throws {
        if isAppleLinked {
            try await ensureAppleSupabaseSession()
            return
        }
        if let token = supabaseAccessToken, userID != nil, !token.isEmpty {
            return
        }
        do {
            try await ensureAppleSupabaseSession()
        } catch {
            try await ensureSupabaseSessionForUpload()
        }
    }

    /// Real Apple → Supabase session required for invite link ownership.
    func ensureAppleSupabaseSession() async throws {
        if isAppleLinked, let token = supabaseAccessToken, userID != nil, !token.isEmpty {
            return
        }
        isBusy = true
        defer { isBusy = false }
        let credential = try await requestAppleCredential()
        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8)
        else {
            throw AuthSessionError.missingIdentityToken
        }
        let session = try await SupabaseAuthAPI.signInWithApple(idToken: idToken)
        applySession(userID: session.userID, accessToken: session.accessToken, appleLinked: true)
    }

    func signOut() {
        isSignedIn = false
        isAppleLinked = false
        userID = nil
        supabaseAccessToken = nil
        statusMessage = nil
    }

    private func requestAppleCredential() async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { cont in
            appleContinuation = cont
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            currentController = controller
            controller.performRequests()
        }
    }
}

enum AuthSessionError: LocalizedError {
    case missingIdentityToken
    case appleCanceled

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken:
            return L10n.inviteNeedApple
        case .appleCanceled:
            return nil
        }
    }
}

extension AuthSessionStore: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        defer {
            currentController = nil
        }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            appleContinuation?.resume(throwing: AuthSessionError.missingIdentityToken)
            appleContinuation = nil
            return
        }
        appleContinuation?.resume(returning: credential)
        appleContinuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        defer {
            isBusy = false
            currentController = nil
            appleContinuation = nil
        }
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            appleContinuation?.resume(throwing: AuthSessionError.appleCanceled)
            return
        }
        appleContinuation?.resume(throwing: error)
        statusMessage = error.localizedDescription
    }
}

extension AuthSessionStore: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
