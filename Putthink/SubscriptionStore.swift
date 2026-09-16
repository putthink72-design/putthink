import StoreKit
import SwiftUI
import UIKit

@MainActor
final class SubscriptionStore: ObservableObject {
    nonisolated static let productIDs: [String] = [
        "com.putthink.putthink.pro.monthly",
        "com.putthink.putthink.pro.quarterly",
        "com.putthink.putthink.pro.semiannual",
        "com.putthink.putthink.pro.yearly",
    ]

    /// Flip to `false` before App Store / External TestFlight review.
    /// Keep `true` only for local field filming builds if you also leave Dev Mode available.
    static let temporarilyUnlockScanStart = false

    @Published private(set) var products: [Product] = []
    @Published private(set) var isSubscribed = false
    @Published var statusMessage: String?
    @Published var isBusy = false

    /// Real StoreKit entitlement, or Dev Mode override.
    func hasProAccess(devMode: DevModeStore) -> Bool {
        isSubscribed || devMode.isDevMode
    }

    var canStartGreenScan: Bool {
        if Self.temporarilyUnlockScanStart { return true }
        return isSubscribed
    }

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = Task { await listenForTransactions() }
        Task { await refresh() }
    }

    func canStartGreenScan(freeRuns: FreeRunsStore, devMode: DevModeStore) -> Bool {
        if Self.temporarilyUnlockScanStart { return true }
        if hasProAccess(devMode: devMode) { return true }
        return freeRuns.balance > 0
    }

    func refresh() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted(by: Self.sortProducts)
            await updateEntitlements()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.checkVerified(verification)
                await updateEntitlements()
                await transaction.finish()
                statusMessage = nil
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func restore() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            await updateEntitlements()
            statusMessage = isSubscribed ? L10n.settingsRestoreSuccess : L10n.settingsRestoreEmpty
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func manageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else { return }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                await UIApplication.shared.open(url)
            }
        }
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            if let transaction = try? Self.checkVerified(result) {
                await updateEntitlements()
                await transaction.finish()
            }
        }
    }

    private func updateEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.checkVerified(result) else { continue }
            if Self.productIDs.contains(transaction.productID) {
                active = true
                break
            }
        }
        isSubscribed = active
    }

    private static func sortProducts(_ lhs: Product, _ rhs: Product) -> Bool {
        periodRank(lhs) < periodRank(rhs)
    }

    private static func periodRank(_ product: Product) -> Int {
        guard let period = product.subscription?.subscriptionPeriod else { return 99 }
        switch (period.unit, period.value) {
        case (.month, 1): return 0
        case (.month, 3): return 1
        case (.month, 6): return 2
        case (.year, 1): return 3
        default: return 50
        }
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }
}
