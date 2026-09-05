import SwiftUI
import SwiftData

@main
struct MonevaApp: App {
    @State private var startupError: String?
    private let container: ModelContainer

    init() {
        #if DEBUG
        monevaSelfCheck()
        #endif
        do {
            // Local-only for now. CloudKit sync is opt-in and lands with the
            // sharing work, not before.
            container = try ModelContainer(
                for: Transaction.self, SpendingCategory.self, Budget.self, BudgetLimit.self, Goal.self,
                Subscription.self, SubscriptionPayment.self, TransactionAllocation.self, MerchantCategoryRule.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
            // Legacy budgets had no currency. Capture the current setting once; never relabel them later.
            for budget in try container.mainContext.fetch(FetchDescriptor<Budget>()) where budget.currency == nil { budget.currency = Money.code }
            try container.mainContext.save()
            SeedData.installIfNeeded(in: container.mainContext)
            // A launch after a quiet week is when overdue charges get caught up.
            do { try SubscriptionEngine.catchUp(in: container.mainContext) }
            catch { _startupError = State(initialValue: "Scheduled payments could not be saved. Open Subscriptions to retry. " + error.localizedDescription) }
        } catch {
            fatalError("Could not open the Moneva store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .alert("Scheduled payments", isPresented: Binding(get: { startupError != nil }, set: { if !$0 { startupError = nil } })) {
                    Button("OK") { startupError = nil }
                } message: { Text(startupError ?? "") }
        }
        .modelContainer(container)
    }
}
