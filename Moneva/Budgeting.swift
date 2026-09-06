import Foundation
import SwiftUI

/// Every number the app shows is computed here, in Swift — never by a model.
enum Budgeting {
    enum LimitState {
        case ok, nearingLimit, atLimit

        /// Thresholds the PRD notifies on: 80% and 100%.
        init(progress: Double) {
            switch progress {
            case ..<0.8: self = .ok
            case ..<1.0: self = .nearingLimit
            default: self = .atLimit
            }
        }
    }

    static func monthStart(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    static func monthRange(for date: Date, calendar: Calendar = .current) -> Range<Date> {
        let start = monthStart(for: date, calendar: calendar)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return start..<end
    }

    static func spent(_ transactions: [Transaction], in range: Range<Date>, scope: Scope, currency: String = Money.code) -> Decimal {
        transactions
            .filter { $0.kind == .expense && $0.scope == scope && $0.currency == currency && range.contains($0.date) }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    static func earned(_ transactions: [Transaction], in range: Range<Date>, scope: Scope, currency: String = Money.code) -> Decimal {
        transactions
            .filter { $0.kind == .income && $0.scope == scope && $0.currency == currency && range.contains($0.date) }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// Running total of expenses by day-of-month, for a spending trend chart.
    /// Days past `now` simply stay flat at the last real total — there are no
    /// future transactions to sum, so no special-casing is needed here.
    static func cumulativeSpending(_ transactions: [Transaction], in range: Range<Date>, scope: Scope, currency: String = Money.code, calendar: Calendar = .current) -> [(day: Int, total: Decimal)] {
        let daysInMonth = calendar.range(of: .day, in: .month, for: range.lowerBound)?.count ?? 30
        return (1...daysInMonth).map { day in
            let dayEnd = calendar.date(byAdding: .day, value: day, to: range.lowerBound) ?? range.upperBound
            let total = spent(transactions, in: range.lowerBound..<min(dayEnd, range.upperBound), scope: scope, currency: currency)
            return (day, total)
        }
    }

    static func progress(spent: Decimal, limit: Decimal) -> Double {
        guard limit > 0 else { return 0 }
        return (spent / limit).doubleValue
    }

    /// Straight-line projection of the month's end total from the pace so far.
    /// Returns nil before a full day has elapsed — one morning is not a pace.
    static func projectedMonthTotal(spent: Decimal, now: Date, calendar: Calendar = .current) -> Decimal? {
        let range = monthRange(for: now, calendar: calendar)
        let elapsed = now.timeIntervalSince(range.lowerBound)
        let full = range.upperBound.timeIntervalSince(range.lowerBound)
        guard elapsed >= 86_400, full > 0 else { return nil }
        return spent * Decimal(Int(full)) / Decimal(Int(elapsed))
    }

    /// When a goal completes at the given monthly contribution.
    static func projectedCompletion(remaining: Decimal, monthlyRate: Decimal, from: Date, calendar: Calendar = .current) -> Date? {
        guard monthlyRate > 0 else { return nil }
        guard remaining > 0 else { return from }
        let months = Int(ceil((remaining / monthlyRate).doubleValue))
        return calendar.date(byAdding: .month, value: months, to: from)
    }
}

#if DEBUG
/// Smallest check that fails loudly if the money math breaks. Runs on launch
/// in debug builds — there is no test target yet.
// ponytail: assert-based self-check, promote to a Swift Testing target when
// the AI drafting layer lands and needs real fixtures.
func monevaSelfCheck() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!

    let sept = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
    let range = Budgeting.monthRange(for: calendar.date(from: DateComponents(year: 2026, month: 9, day: 17))!, calendar: calendar)
    assert(range.lowerBound == sept, "month range must start on the 1st")
    assert(range.upperBound == calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!, "month range must end at the next 1st")

    let food = SpendingCategory(name: "Food", symbol: "fork.knife", tintHex: "B5813F", softHex: "F0E6D6")
    let inside = Transaction(amount: 42, date: calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))!, merchant: "Bravo", category: food)
    let outside = Transaction(amount: 100, date: calendar.date(from: DateComponents(year: 2026, month: 8, day: 30))!, merchant: "Old", category: food)
    let sharedTx = Transaction(amount: 35, date: calendar.date(from: DateComponents(year: 2026, month: 9, day: 4))!, merchant: "Kontakt", scope: .shared, category: food)
    let salary = Transaction(amount: 2400, date: calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))!, merchant: "Salary", kind: .income, category: nil)
    let all = [inside, outside, sharedTx, salary]

    assert(Budgeting.spent(all, in: range, scope: .personal) == 42, "scope and date filters must both apply")
    assert(Budgeting.spent(all, in: range, scope: .shared) == 35, "shared scope is separate money")
    assert(Budgeting.earned(all, in: range, scope: .personal) == 2400, "income must not count as spending")

    let trend = Budgeting.cumulativeSpending(all, in: range, scope: .personal, calendar: calendar)
    assert(trend.count == 30, "September has 30 days")
    assert(trend[1].total == 0, "day 2 is before the first personal expense")
    assert(trend[2].total == 42, "day 3 picks up the Bravo expense")
    assert(trend.last!.total == 42, "no more expenses after day 3, total stays flat")

    assert(Budgeting.progress(spent: 400, limit: 500) == 0.8, "progress is spent over limit")
    assert(Budgeting.progress(spent: 100, limit: 0) == 0, "a zero limit must not divide")
    if case .ok = Budgeting.LimitState(progress: 0.79) {} else { assertionFailure("79% is still ok") }
    if case .nearingLimit = Budgeting.LimitState(progress: 0.8) {} else { assertionFailure("80% must warn") }
    if case .atLimit = Budgeting.LimitState(progress: 1.0) {} else { assertionFailure("100% must alert") }

    let half = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16))!
    let projected = Budgeting.projectedMonthTotal(spent: 1000, now: half, calendar: calendar)
    assert(projected != nil && projected! > 1900 && projected! < 2100, "half a month at 1000 projects to about 2000")
    assert(Budgeting.projectedMonthTotal(spent: 10, now: sept, calendar: calendar) == nil, "no pace on day one")

    assert(AmountField.parse("2000") == 2000, "plain digits parse whole")
    assert(AmountField.parse("42,50") == Decimal(string: "42.5"), "comma is a decimal separator")
    assert(AmountField.parse("42.50") == Decimal(string: "42.5"), "so is a dot")
    assert(AmountField.parse("") == 0, "empty means zero, not a crash")
    assert(AmountField.parse("abc") == 0, "letters are dropped")

    let transport = SpendingCategory(name: "Transport", symbol: "car", tintHex: "3F7684", softHex: "DCE7EA")
    let other = SpendingCategory(name: "Other", symbol: "square.grid.2x2", tintHex: "78746A", softHex: "E4E2DB")
    let catalogue = [food, transport, other]

    assert(Money.parse("42.499") == Decimal(string: "42.499"), "exact model decimal survives without float conversion")
    assert(Money.parse("-5") == nil && Money.parse("NaN") == nil && Money.parse("5abc") == nil && Money.parse("1.2.3") == nil, "malformed money is rejected, not partially parsed")
    assert(!Money.valid(Decimal(string: "1.001")!, currency: "USD"), "invalid currency precision requires review")
    assert(Money.valid(1, currency: "JPY") && !Money.valid(Decimal(string: "1.1")!, currency: "JPY"), "zero-decimal currencies stay exact")
    assert(DraftResolver.category(named: "food", in: catalogue) === food)
    assert(DraftResolver.category(named: "Unknown", in: catalogue) == nil, "unknown category requires review")
    let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))!
    assert(DraftResolver.date(DraftDate(offsetDays: -1, year: nil, month: nil, day: nil), now: today, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))!)
    assert(DraftResolver.date(DraftDate(offsetDays: nil, year: 2026, month: 2, day: 30), calendar: calendar) == nil, "invalid dates never normalize silently")

    // The exact glyph is the locale's business — "$", "US$" and "USD" are all
    // correct answers. Only the shape is asserted.
    for code in ["USD", "AZN", "EUR"] {
        let symbol = Money.symbol(for: code)
        assert(!symbol.isEmpty, "\(code) must print something to put beside the field")
        assert(symbol.allSatisfy { !$0.isNumber && !$0.isWhitespace }, "\(code) symbol must carry no digits or spaces")
    }

    assert(Money.flag(for: "USD") == "🇺🇸", "a currency code opens with its country")
    assert(Money.flag(for: "AZN") == "🇦🇿", "and so does every other one")
    assert(Money.flag(for: "XAU").isEmpty, "gold belongs to no country, so it flies no flag")
    assert(Money.flag(for: "ANG").isEmpty, "a retired region draws empty boxes, not a flag")

    // Vision hands text back in detection order; a receipt only reads correctly
    // top to bottom, then left to right within a line.
    let scanned: [(text: String, rect: CGRect)] = [
        ("42.00", CGRect(x: 300, y: 200, width: 60, height: 20)),
        ("Bravo Market", CGRect(x: 20, y: 10, width: 200, height: 22)),
        ("Total", CGRect(x: 20, y: 202, width: 60, height: 20))
    ]
    assert(ReceiptText.ordered(scanned) == "Bravo Market\nTotal  42.00", "receipt text reads top-down, left-right")
    assert(ReceiptText.ordered([]).isEmpty, "an empty scan is empty text, not a crash")

    // Recurring payments: the day of the month is an anchor, not a stride, so
    // a short February must not drag every later charge back with it.
    let jan31 = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31))!
    let feb = Subscriptions.nextDate(after: jan31, anchorDay: 31, calendar: calendar)
    assert(calendar.component(.day, from: feb) == 28, "the 31st clamps to the end of February")
    let mar = Subscriptions.nextDate(after: feb, anchorDay: 31, calendar: calendar)
    assert(calendar.component(.day, from: mar) == 31, "and comes back to the 31st in March")
    assert(Subscriptions.billingPeriod(for: feb, calendar: calendar) == "2026-02", "a period is the month the charge belongs to")

    // Two months went by with the app closed: both are owed, once each.
    let due = Subscriptions.duePeriods(
        nextPaymentDate: calendar.date(from: DateComponents(year: 2026, month: 7, day: 5))!,
        anchorDay: 5,
        processed: [],
        now: calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))!,
        calendar: calendar
    )
    assert(due.map(\.period) == ["2026-07", "2026-08"], "every missed month is owed exactly once")

    let deduped = Subscriptions.duePeriods(
        nextPaymentDate: calendar.date(from: DateComponents(year: 2026, month: 7, day: 5))!,
        anchorDay: 5,
        processed: ["2026-07"],
        now: calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))!,
        calendar: calendar
    )
    assert(deduped.map(\.period) == ["2026-08"], "a month already on file is never charged twice")

    assert(Subscriptions.reminderDate(paymentDate: sept, daysBefore: nil, calendar: calendar) == nil, "no reminder, no date")
    assert(Subscriptions.reminderDate(paymentDate: sept, daysBefore: 3, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 8, day: 29))!, "a 3 day reminder fires 3 days before")

    let netflix = Subscription(name: "Netflix", amount: 12, nextPaymentDate: sept, category: food, calendar: calendar)
    let gym = Subscription(name: "Gym", amount: 45, nextPaymentDate: sept, category: food, calendar: calendar)
    gym.status = .paused
    assert(Subscriptions.monthlyTotal([netflix, gym]) == 12, "a paused subscription costs nothing this month")

    // A fixed term stops billing: 24 instalments from September 2026 and no more.
    let loan = Subscription(name: "Car loan", amount: 300, nextPaymentDate: sept,
                            endDate: calendar.date(from: DateComponents(year: 2028, month: 8, day: 1))!,
                            category: food, calendar: calendar)
    assert(Subscriptions.remainingPayments(nextPaymentDate: sept, anchorDay: 1, endDate: loan.endDate, calendar: calendar) == 24, "September 2026 to August 2028 inclusive is 24 monthly payments")
    assert(Subscriptions.remainingPayments(nextPaymentDate: sept, anchorDay: 1, endDate: nil, calendar: calendar) == nil, "an open-ended plan has no payment count")
    let afterTerm = calendar.date(from: DateComponents(year: 2028, month: 12, day: 1))!
    assert(Subscriptions.duePeriods(nextPaymentDate: sept, anchorDay: 1, processed: [], endDate: loan.endDate, now: afterTerm, calendar: calendar).count == 24, "catch-up never bills past the last payment date")
    assert(Subscriptions.hasEnded(loan, on: afterTerm, calendar: calendar), "a term that is over has ended")
    assert(!Subscriptions.hasEnded(loan, on: sept, calendar: calendar), "a term still running has not ended")
    assert(Subscriptions.monthlyTotal([loan], now: afterTerm, calendar: calendar) == 0, "a finished plan costs nothing this month")
    assert(Subscriptions.monthlyTotal([loan], now: sept, calendar: calendar) == 300, "a running plan still costs its instalment")

    // A detected day of the month resolves forward, never into the past.
    let mid = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17))!
    assert(calendar.component(.month, from: SubscriptionResolver.nextDate(dayOfMonth: 25, now: mid, calendar: calendar)) == 9, "a day still to come stays in this month")
    assert(calendar.component(.month, from: SubscriptionResolver.nextDate(dayOfMonth: 3, now: mid, calendar: calendar)) == 10, "a day already past moves to next month")

    // Categories: names are unique per scope, archived ones leave the picker.
    let shared = SpendingCategory(name: "Rent", symbol: "house", tintHex: "7A5B86", softHex: "E7DEE8", scope: .shared)
    let archivedCategory = SpendingCategory(name: "Old", symbol: "circle", tintHex: "78746A", softHex: "E4E2DB")
    archivedCategory.isArchived = true
    let library = catalogue + [shared, archivedCategory]
    assert(!CategoryLibrary.isNameAvailable("food", scope: .personal, in: library), "a name is taken whatever its case")
    assert(CategoryLibrary.isNameAvailable("Food", scope: .shared, in: library), "the same name is free in the other scope")
    assert(CategoryLibrary.isNameAvailable("Food", scope: .personal, in: library, excluding: food), "renaming a category does not collide with itself")
    assert(!CategoryLibrary.isNameAvailable("  ", scope: .personal, in: library), "a blank name is never valid")
    assert(!CategoryLibrary.visible(library, scope: .personal).contains { $0 === archivedCategory }, "archived categories leave the picker")
    assert(!CategoryLibrary.visible(library, scope: .personal).contains { $0 === shared }, "shared categories stay out of a personal budget")
    assert(CategoryLibrary.visible(library, scope: .shared).last === shared, "in a shared budget, personal comes first and shared last")
    assert(CategoryLibrary.search(library, for: "tran").map(\.name) == ["Transport"], "search matches part of a name")

    // Income has its own catalogue: the two sides never leak into each other.
    let salaryCategory = SpendingCategory(name: "Salary", symbol: "briefcase", tintHex: "4F7A55", softHex: "DDE8DD", kind: .income)
    let ledger = library + [salaryCategory]
    assert(!CategoryLibrary.visible(ledger, scope: .personal).contains { $0 === salaryCategory }, "income categories stay out of the expense picker")
    assert(CategoryLibrary.visible(ledger, scope: .personal, kind: .income).map(\.name) == ["Salary"], "the income picker shows only income categories")
    assert(CategoryLibrary.visible(ledger, scope: .personal, kind: nil).contains { $0 === salaryCategory }, "both sides list together when no kind is asked for")
    assert(!CategoryLibrary.isSelectable(salaryCategory, scope: .personal), "an income category is never selectable on an expense")
    assert(CategoryLibrary.isSelectable(salaryCategory, scope: .personal, kind: .income), "an income category is selectable on income")
    assert(CategoryLibrary.isNameAvailable("Food", scope: .personal, kind: .income, in: ledger), "the same name is free on the other side of the ledger")
    assert(!CategoryLibrary.isNameAvailable("salary", scope: .personal, kind: .income, in: ledger), "an income name is taken whatever its case")

    aiFeaturesSelfCheck()

    let eta = Budgeting.projectedCompletion(remaining: 760, monthlyRate: 200, from: sept, calendar: calendar)
    assert(eta == calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!, "760 at 200 a month takes 4 months")
    assert(Budgeting.projectedCompletion(remaining: 100, monthlyRate: 0, from: sept, calendar: calendar) == nil, "no rate, no date")

    assert(AmountField.editable(0).isEmpty, "an empty amount field never seeds a leading zero to type around")
    assert(AmountField.editable(Decimal(string: "1250.75")!) == "1250.75", "an existing amount comes back editable, unrounded and ungrouped")
}
#endif
