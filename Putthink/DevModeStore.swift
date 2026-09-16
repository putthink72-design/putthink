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
        // Default OFF for External TF / App Review. Toggle still works for filming.
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            isDevMode = false
        } else {
            isDevMode = UserDefaults.standard.bool(forKey: Self.key)
        }
    }
}
