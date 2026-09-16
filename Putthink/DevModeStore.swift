import Foundation
import SwiftUI

/// Temporary build switch: Dev = treat as Pro (all gates open). Prod = real entitlement checks.
@MainActor
final class DevModeStore: ObservableObject {
    private static let key = "putthink.devMode.enabled"

    @Published var isDevMode: Bool {
        didSet {
            UserDefaults.standard.set(isDevMode, forKey: Self.key)
        }
    }

    var isProductionMode: Bool { !isDevMode }

    init() {
        // Default ON while shipping unfinished monetization / Supabase wiring.
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            isDevMode = true
        } else {
            isDevMode = UserDefaults.standard.bool(forKey: Self.key)
        }
    }
}
