import Foundation

enum AccountDeleteAPI {
    static func deleteAccount(accessToken: String) async throws {
        guard PutthinkSupabaseConfig.isConfigured,
              let base = URL(string: PutthinkSupabaseConfig.urlString)
        else { throw ShowcaseUploadError.notConfigured }

        let url = base
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("delete-account")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(PutthinkSupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) else {
            let body = String(data: data, encoding: .utf8) ?? "delete-account \(code)"
            throw ShowcaseUploadError.http(code, body)
        }
    }
}
