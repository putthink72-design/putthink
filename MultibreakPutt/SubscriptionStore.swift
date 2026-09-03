import StoreKit
import SwiftUI
import UIKit

@MainActor
final class SubscriptionStore: ObservableObject {
    nonisolated static let productIDs: [String] = [
        "com.scanpar.scanpar.pro.monthly",
        "com.scanpar.scanpar.pro.quarterly",
        "com.scanpar.scanpar.pro.semiannual",
        "com.scanpar.scanpar.pro.yearly",
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var isSubscribed = false
    @Published private(set) var introEligibleProductIDs: Set<String> = []
    @Published var statusMessage: String?
    @Published var isBusy = false

    private var transactionListener: Task<Void, Never>?

    init() {
        transactionListener = Task { await listenForTransactions() }
        Task { await refresh() }
    }

    func refresh() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted(by: Self.sortProducts)
            await refreshIntroEligibility()
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

    private func refreshIntroEligibility() async {
        var eligible: Set<String> = []
        for product in products {
            if let subscription = product.subscription,
               subscription.introductoryOffer != nil,
               await subscription.isEligibleForIntroOffer {
                eligible.insert(product.id)
            }
        }
        introEligibleProductIDs = eligible
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
