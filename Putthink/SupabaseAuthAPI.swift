import Foundation

/// Supabase Auth REST (no SPM client).
enum SupabaseAuthAPI {
    struct Session: Sendable {
        var accessToken: String
        var userID: String
    }

    static func ensureDeviceSession() async throws -> Session {
        guard PutthinkSupabaseConfig.isConfigured,
              let base = URL(string: PutthinkSupabaseConfig.urlString)
        else { throw ShowcaseUploadError.notConfigured }

        let device = DeviceKeychain.deviceClaimToken()
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        // Placeholder mailbox (not a real inbox). Supabase rejects `.local` TLDs.
        // Disable “Confirm email” under Authentication → Providers → Email.
        let email = "device-\(device)@example.com"
        let password = "Pt!\(String(device.prefix(24)))Aa1"

        if let signedIn = try? await passwordGrant(base: base, email: email, password: password) {
            return signedIn
        }
        try await signUp(base: base, email: email, password: password)
        do {
            return try await passwordGrant(base: base, email: email, password: password)
        } catch {
            throw ShowcaseUploadError.auth(
                "Sign-in failed after signup. In Supabase → Authentication → Providers → Email, turn OFF “Confirm email”, then retry."
            )
        }
    }

    /// Sign in with Apple identity token (Supabase Auth provider must be enabled).
    static func signInWithApple(idToken: String) async throws -> Session {
        guard PutthinkSupabaseConfig.isConfigured,
              let base = URL(string: PutthinkSupabaseConfig.urlString)
        else { throw ShowcaseUploadError.notConfigured }

        var comps = URLComponents(
            url: base.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]
        guard let url = comps.url else { throw ShowcaseUploadError.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAnonHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "apple",
            "id_token": idToken,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              let user = json["user"] as? [String: Any],
              let uid = user["id"] as? String
        else {
            throw ShowcaseUploadError.auth(
                String(data: data, encoding: .utf8)
                    ?? "Apple Sign In failed (\(code)). Enable Apple provider in Supabase Auth."
            )
        }
        return Session(accessToken: token, userID: uid)
    }

    private static func signUp(base: URL, email: String, password: String) async throws {
        let url = base.appendingPathComponent("auth/v1/signup")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAnonHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        // 200/201 ok; 422 user already exists
        if (200...299).contains(code) || code == 422 { return }
        throw ShowcaseUploadError.auth(String(data: data, encoding: .utf8) ?? "signup \(code)")
    }

    private static func passwordGrant(base: URL, email: String, password: String) async throws -> Session {
        var comps = URLComponents(
            url: base.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        guard let url = comps.url else { throw ShowcaseUploadError.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAnonHeaders(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              let user = json["user"] as? [String: Any],
              let uid = user["id"] as? String
        else {
            throw ShowcaseUploadError.auth(String(data: data, encoding: .utf8) ?? "token \(code)")
        }
        return Session(accessToken: token, userID: uid)
    }

    private static func applyAnonHeaders(_ req: inout URLRequest) {
        req.setValue(PutthinkSupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(PutthinkSupabaseConfig.anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
}
