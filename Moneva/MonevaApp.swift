import SwiftUI
import SwiftData

@main
struct MonevaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var startupError: String?
    private let container: ModelContainer

    init() {
        #if DEBUG
        monevaSelfCheck()
        #endif
        do {
            // Explicitly opted out of SwiftData's own CloudKit mirroring:
            // `ModelConfiguration`'s default `cloudKitDatabase` is `.automatic`,
            // which turns itself on the moment the iCloud/CloudKit entitlement
            // exists (added for family sharing) — that would mirror this
            // *entire* local store, personal scope included, to the private
            // database. Family sync is deliberately a separate, hand-rolled
            // CKSyncEngine layer (FamilySync.swift) that only ever touches
            // scope == .shared records; this store stays local-only.
            container = try ModelContainer(
                for: Transaction.self, SpendingCategory.self, Budget.self, BudgetLimit.self, Goal.self,
                Subscription.self, SubscriptionPayment.self, TransactionAllocation.self, MerchantCategoryRule.self,
                FamilyMember.self, Settlement.self, Account.self, Transfer.self,
                MerchantEmbedding.self, CategoryExemplar.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: false, cloudKitDatabase: .none)
            )
            // Legacy budgets had no currency. Capture the current setting once; never relabel them later.
            for budget in try container.mainContext.fetch(FetchDescriptor<Budget>()) where budget.currency == nil { budget.currency = Money.code }
            try container.mainContext.save()
            SeedData.installIfNeeded(in: container.mainContext)
            // A launch after a quiet week is when overdue charges get caught up.
            do { try SubscriptionEngine.catchUp(in: container.mainContext) }
            catch { _startupError = State(initialValue: "Scheduled payments could not be saved. Open Subscriptions to retry. " + error.localizedDescription) }
            // No-op until a family share exists.
            FamilySyncEngine.shared.catchUp(in: container.mainContext)
        } catch {
            fatalError("Could not open the Moneva store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                #if DEBUG
                .task { await financialToolModelSelfCheck() }
                #endif
                .alert("Scheduled payments", isPresented: Binding(get: { startupError != nil }, set: { if !$0 { startupError = nil } })) {
                    Button("OK") { startupError = nil }
                } message: { Text(startupError ?? "") }
        }
        .modelContainer(container)
    }
}
