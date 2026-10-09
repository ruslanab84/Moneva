import StoreKit
import Observation

/// Single source of truth for "is this user Pro". One entitlement covers the
/// subscriptions and the lifetime purchase. Note `StoreKit.Transaction`: a bare
/// `Transaction` is the app's SwiftData model.
@MainActor @Observable
final class ProStore {
    nonisolated static let productIDs = [
        "RuslanAbd.Moneva.pro.monthly",
        "RuslanAbd.Moneva.pro.yearly",
        "RuslanAbd.Moneva.pro.lifetime",
    ]
    private static let cacheKey = "pro.cachedIsPro"

    /// Starts from the last known answer so a Pro user sees no banner/lock flash at launch.
    private(set) var isPro = UserDefaults.standard.bool(forKey: ProStore.cacheKey)
    private(set) var products: [Product] = []
    @ObservationIgnored private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task {
            await loadProducts()
            await refresh()
        }
    }

    deinit { updates?.cancel() }

    nonisolated static func unlocks(productID: String, isRevoked: Bool) -> Bool {
        !isRevoked && productIDs.contains(productID)
    }

    func loadProducts() async {
        let loaded = (try? await Product.products(for: Self.productIDs)) ?? []
        products = loaded.sorted { (Self.productIDs.firstIndex(of: $0.id) ?? 0) < (Self.productIDs.firstIndex(of: $1.id) ?? 0) }
    }

    func refresh() async {
        var pro = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               Self.unlocks(productID: transaction.productID, isRevoked: transaction.revocationDate != nil) {
                pro = true
            }
        }
        isPro = pro
        UserDefaults.standard.set(pro, forKey: Self.cacheKey)
    }

    /// Returns a user-facing error, or nil on success, cancel or pending (those are not errors).
    func purchase(_ product: Product) async -> String? {
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return String(localized: "The purchase could not be verified.") }
                await transaction.finish()
                await refresh()
                return nil
            case .userCancelled, .pending:
                return nil
            @unknown default:
                return nil
            }
        } catch {
            return error.localizedDescription
        }
    }

    func restore() async -> String? {
        do {
            try await AppStore.sync()
            await refresh()
            return isPro ? nil : String(localized: "No previous purchase found for this Apple ID.")
        } catch {
            return error.localizedDescription
        }
    }
}
