import AppIntents
import Foundation

/// The Control Center button and the widgets' "+": opens Ledgea on a new transaction.
/// Compiled into both the app and the widget extension; with `openAppWhenRun` the system
/// runs it in the app. The flag rides the App Group defaults so a cold launch sees it too.
nonisolated struct AddTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add transaction"
    static let description = IntentDescription("Opens Ledgea on a new transaction.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        BudgetSnapshot.defaults.set(true, forKey: BudgetSnapshot.quickAddKey)
        return .result()
    }
}
