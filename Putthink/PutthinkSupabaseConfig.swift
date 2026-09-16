import Foundation

/// Shared Supabase project (same as PutthinkSite).
/// Priority: Info.plist keys → hardcoded constants below.
enum PutthinkSupabaseConfig {
    /// Optional Info.plist / build setting overrides.
    private static let plistURLKey = "PUTTHINK_SUPABASE_URL"
    private static let plistAnonKey = "PUTTHINK_SUPABASE_ANON_KEY"

    /// Fill after creating the Supabase project (or set plist keys).
    private static let hardcodedURL = "https://akyqqqcytdrheqvjvkps.supabase.co"
    private static let hardcodedAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFreXFxcWN5dGRyaGVxdmp2a3BzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg5MjU5NDksImV4cCI6MjEwNDUwMTk0OX0.NLtUtEt7bfTdU86C_RTh6ELCiw_dFQrmn8X5QLJCd_E"

    static var urlString: String {
        if let plist = Bundle.main.object(forInfoDictionaryKey: plistURLKey) as? String,
           !plist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plist.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return hardcodedURL
    }

    static var anonKey: String {
        if let plist = Bundle.main.object(forInfoDictionaryKey: plistAnonKey) as? String,
           !plist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plist.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return hardcodedAnonKey
    }

    static var isConfigured: Bool {
        guard let url = URL(string: urlString), !urlString.isEmpty, !anonKey.isEmpty else {
            return false
        }
        return url.scheme == "https"
    }

    static let claimFreeTierPath = "claim-free-tier"
    static let consumeFreeRunPath = "consume-free-run"
    static let storageBucket = "putt-showcase"
}
