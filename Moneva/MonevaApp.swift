import SwiftUI
import SwiftData

@main
struct MonevaApp: App {
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
                configurations: ModelConfiguration(isStoredInMemoryOnly: false)
            )
            SeedData.installIfNeeded(in: container.mainContext)
        } catch {
            fatalError("Could not open the Moneva store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
