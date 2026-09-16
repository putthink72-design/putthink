import Foundation
import UIKit

/// Parses invite codes from Universal Links, custom scheme, or clipboard.
enum InviteDeepLink {
    static let codePattern = #"^[0-9A-Za-z]{8}$"#

    static func parseInviteCode(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let i = parts.firstIndex(of: "i"), parts.index(after: i) < parts.endIndex {
            let code = parts[parts.index(after: i)]
            return normalizedCode(code)
        }
        if url.host == "i", let code = url.pathComponents.last, code != "/" {
            return normalizedCode(code)
        }
        return nil
    }

    static func normalizedCode(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: codePattern, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    /// First-launch clipboard pairing (landing page copies `https://putthink.com/i/{code}`).
    @MainActor
    static func codeFromClipboardIfPresent() -> String? {
        let board = UIPasteboard.general
        if let url = board.url, let code = parseInviteCode(from: url) {
            return code
        }
        if let strings = board.strings {
            for s in strings {
                if let url = URL(string: s), let code = parseInviteCode(from: url) {
                    return code
                }
                if let code = normalizedCode(s) {
                    return code
                }
            }
        }
        if let s = board.string {
            if let url = URL(string: s), let code = parseInviteCode(from: url) {
                return code
            }
            return normalizedCode(s)
        }
        return nil
    }
}
