import Foundation

/// What the widgets show, written by the app after every save. The widget extension
/// never opens the SwiftData store — it only reads this one value from the App Group
/// defaults on this device. Amounts arrive pre-formatted so the glyphs match the app.
nonisolated struct BudgetSnapshot: Codable, Equatable {
    enum State: String, Codable { case ok, near, over }

    struct Row: Codable, Equatable, Identifiable {
        var id: String { name }
        var name: String
        var symbol: String
        var tintHex: String
        var progress: Double
        /// "₼120.00 / ₼200.00"
        var text: String
    }

    var monthStart: Date
    var shared: Bool
    /// The remaining amount, or the overspend once `isOver`.
    var left: String
    var isOver: Bool
    var total: String
    var progress: Double
    var state: State
    /// Top three category limits by progress.
    var categories: [Row]

    static let appGroup = "group.RuslanAbd.Moneva"
    static let key = "widget.budget"
    /// Set by `AddTransactionIntent`, cleared by RootView once it opens the Add sheet.
    static let quickAddKey = "quickAdd.pending"
    /// One shared instance, so `@AppStorage(store:)` in the app sees the intent's write.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: appGroup) ?? .standard

    static func load(from defaults: UserDefaults = defaults) -> BudgetSnapshot? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(BudgetSnapshot.self, from: $0) }
    }

    /// nil clears it: no budget this month means the widget says so instead of showing stale numbers.
    static func store(_ snapshot: BudgetSnapshot?, in defaults: UserDefaults = defaults) {
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
