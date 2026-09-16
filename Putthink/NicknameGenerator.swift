import Foundation

/// Auto nicknames: [golf modifier] + [animal] + [4 digits]. KO word bank only (locale-agnostic identity).
enum NicknameGenerator {
    static let modifiers: [String] = [
        "버디", "이글", "알바트로스", "파", "보기", "홀인원",
        "그린", "페어웨이", "롱퍼트", "어프로치", "벙커", "스크래치",
    ]

    static let nouns: [String] = [
        "오리너구리", "여우", "독수리", "다람쥐", "너구리", "부엉이", "고슴도치", "수달",
        "펭귄", "판다", "코알라", "호랑이", "늑대", "사슴", "참새", "두더지",
    ]

    struct Components: Equatable, Sendable {
        var modifier: String
        var noun: String
        var digits: String

        var value: String { modifier + noun + digits }
    }

    static func random() -> Components {
        Components(
            modifier: modifiers.randomElement()!,
            noun: nouns.randomElement()!,
            digits: randomDigits()
        )
    }

    /// Keep modifier+noun; redraw 0000...9999 (leading zeros allowed).
    static func redrawDigits(keeping base: Components) -> Components {
        var next = base
        next.digits = randomDigits()
        return next
    }

    static func randomDigits() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }
}

/// Lightweight blocklist for user-typed nicknames (auto word-bank skips this).
enum NicknameProfanityFilter {
    private static let blocked: [String] = [
        "씨발", "시발", "병신", "지랄", "니미", "니애미", "꺼져", "좆", "존나",
        "병신", "새끼", "개새끼", "미친놈", "미친년", "보지", "자지",
        "fuck", "shit", "bitch", "asshole", "cunt", "dick",
    ]

    static func isAllowed(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let folded = trimmed.lowercased()
        for word in blocked {
            if folded.contains(word.lowercased()) { return false }
        }
        return true
    }
}
