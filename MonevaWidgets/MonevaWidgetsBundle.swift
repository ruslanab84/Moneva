import SwiftUI
import WidgetKit

@main
struct MonevaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BudgetWidget()
        AddTransactionControl()
    }
}

/// Control Center (and Lock Screen / Action button) shortcut straight to a new transaction.
struct AddTransactionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "RuslanAbd.Moneva.add") {
            ControlWidgetButton(action: AddTransactionIntent()) {
                Label("Add transaction", systemImage: "plus")
            }
        }
        .displayName("Add transaction")
        .description("Opens Ledgea on a new transaction.")
    }
}
