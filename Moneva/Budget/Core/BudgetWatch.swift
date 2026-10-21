import Foundation
import SwiftData
import WidgetKit

/// Keeps budget alerts and the widget snapshot current. Same root-cause hook as
/// FamilySync: one observer on the main context's saves instead of a call at every
/// save site, so manual entry, edits, deletes, subscription catch-up and incoming
/// family changes all count.
enum BudgetWatch {
    private static var context: ModelContext?
    private static var observer: NSObjectProtocol?

    static func start(_ context: ModelContext) {
        guard observer == nil else { return }
        Self.context = context
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: .main) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        refresh()
    }

    /// Also called when the app leaves the foreground: a scope or currency switch, or
    /// a new month, changes what the widget should show without any save.
    static func refresh(now: Date = .now) {
        guard let context else { return }
        let result = evaluate(in: context, now: now)
        BudgetAlerts.notify(result.lines)
        guard result.snapshot != BudgetSnapshot.load() else { return }
        BudgetSnapshot.store(result.snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Every watched line of this month's budgets (all scopes and currencies, for alerts),
    /// and the widget snapshot for the active scope and display currency. No side effects.
    static func evaluate(in context: ModelContext, now: Date, calendar: Calendar = .current, defaults: UserDefaults = .standard) -> (lines: [Budgeting.BudgetLine], snapshot: BudgetSnapshot?) {
        let month = Budgeting.monthStart(for: now, calendar: calendar)
        // Last month too: category rollover reads its leftover.
        let since = calendar.date(byAdding: .month, value: -1, to: month) ?? month
        let budgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        let transactions = (try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.date >= since }))) ?? []

        let current = budgets.filter { $0.monthStart == month }.map { budget in
            (budget: budget, lines: Budgeting.lines(for: budget, transactions: transactions, budgets: budgets, rollover: rolloverOn(budget.scope, defaults: defaults), calendar: calendar))
        }
        let scope = defaults.string(forKey: "scope").flatMap(Scope.init(rawValue:)) ?? .personal
        let currency = defaults.string(forKey: Money.storageKey) ?? Money.code
        let active = current.first { $0.budget.scope == scope && ($0.budget.currency ?? currency) == currency }
        return (current.flatMap(\.lines), active.flatMap { snapshot($0.lines, monthStart: month, now: now, calendar: calendar) })
    }

    /// Same gate as BudgetView: carry-over is Pro, and the per-scope switch defaults on.
    static func rolloverOn(_ scope: Scope, defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: ProStore.cacheKey) && (defaults.object(forKey: Budgeting.rolloverKey(scope)) as? Bool ?? true)
    }

    static func snapshot(_ lines: [Budgeting.BudgetLine], monthStart: Date, now: Date, calendar: Calendar = .current) -> BudgetSnapshot? {
        guard let total = lines.first(where: \.isTotal) else { return nil }
        let progress = Budgeting.progress(spent: total.spent, limit: total.limit)
        let daysRemaining = Budgeting.daysRemaining(in: Budgeting.monthRange(for: now, calendar: calendar), from: now, calendar: calendar)
        let state: BudgetSnapshot.State = switch Budgeting.LimitState(progress: progress, daysRemaining: daysRemaining) {
        case .ok: .ok
        case .nearingLimit: .near
        case .atLimit: .over
        }
        let rows = lines.filter { !$0.isTotal }
            .map { (line: $0, progress: Budgeting.progress(spent: $0.spent, limit: $0.limit)) }
            .sorted { $0.progress > $1.progress }
            .prefix(3)
            .map { item in
                BudgetSnapshot.Row(
                    name: item.line.category?.name ?? String(localized: "Uncategorised"),
                    symbol: item.line.category?.symbol ?? "circle",
                    tintHex: item.line.category?.tintHex ?? "78746A",
                    progress: item.progress,
                    text: "\(item.line.spent.money(item.line.currency)) / \(item.line.limit.money(item.line.currency))")
            }
        let left = total.limit - total.spent
        return BudgetSnapshot(
            monthStart: monthStart, shared: total.scope == .shared,
            left: (left < 0 ? -left : left).money(total.currency), isOver: left < 0,
            total: total.limit.money(total.currency), progress: progress, state: state, categories: Array(rows))
    }
}
