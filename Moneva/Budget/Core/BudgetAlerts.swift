import Foundation
import UserNotifications

/// Local notifications when a month's budget or one of its category limits reaches
/// 75, 90 and 100%. Opt-in from Settings — permission is asked only when the switch
/// is turned on, same rule as subscription reminders.
enum BudgetAlerts {
    static let enabledKey = "budgetAlerts.on"
    static let firedKey = "budgetAlerts.fired"

    /// Which lines crossed a new threshold, and the fired state to keep. Only the
    /// current lines' keys survive, so last month's entries fall away on their own
    /// and the state never grows past one month of budgets.
    static func due(_ lines: [Budgeting.BudgetLine], fired: [String: Int]) -> (alerts: [(line: Budgeting.BudgetLine, threshold: Int)], fired: [String: Int]) {
        var alerts: [(line: Budgeting.BudgetLine, threshold: Int)] = []
        var next: [String: Int] = [:]
        for line in lines {
            let before = fired[line.key] ?? 0
            if let threshold = Budgeting.alertThreshold(spent: line.spent, limit: line.limit, alreadyFired: before) {
                alerts.append((line, threshold))
                next[line.key] = threshold
            } else if before > 0 {
                // Spending that drops back (a refund, a deleted row) never re-arms a threshold this month.
                next[line.key] = before
            }
        }
        return (alerts, next)
    }

    static func notify(_ lines: [Budgeting.BudgetLine], defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: enabledKey) else { return }
        let stored = defaults.data(forKey: firedKey).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        let result = due(lines, fired: stored)
        if result.fired != stored { defaults.set(try? JSONEncoder().encode(result.fired), forKey: firedKey) }
        for alert in result.alerts {
            UNUserNotificationCenter.current().add(request(alert.line, threshold: alert.threshold)) { error in
                if let error { NSLog("Budget alert could not be scheduled: %@", error.localizedDescription) }
            }
        }
    }

    static func request(_ line: Budgeting.BudgetLine, threshold: Int) -> UNNotificationRequest {
        let name = line.category?.name ?? String(localized: "Uncategorised")
        let content = UNMutableNotificationContent()
        switch (line.isTotal, line.scope, threshold >= 100) {
        case (true, .personal, true): content.title = String(localized: "Monthly budget reached")
        case (true, .shared, true): content.title = String(localized: "Shared budget reached")
        case (true, .personal, false): content.title = String(localized: "\(threshold)% of your monthly budget used")
        case (true, .shared, false): content.title = String(localized: "\(threshold)% of the shared budget used")
        case (false, _, true): content.title = String(localized: "\(name): limit reached")
        case (false, _, false): content.title = String(localized: "\(name): \(threshold)% of limit used")
        }
        let left = line.limit - line.spent
        content.body = left >= 0
            ? String(localized: "\(left.money(line.currency)) left of \(line.limit.money(line.currency)).")
            : String(localized: "\((-left).money(line.currency)) over \(line.limit.money(line.currency)).")
        content.sound = .default
        // Stable id per line: a later threshold replaces the earlier banner instead of stacking.
        return UNNotificationRequest(identifier: "budget-\(line.key)", content: content, trigger: nil)
    }
}
