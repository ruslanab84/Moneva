import Foundation
import SwiftUI
#if DEBUG
import SwiftData
import UserNotifications
#endif

/// Every number the app shows is computed here, in Swift — never by a model.
enum Budgeting {
    struct Forecast: Hashable {
        var currency: String
        var balance: Decimal
        var income: Decimal
        var subscriptions: Decimal
        var expenses: Decimal?
        var historyMonths: Int
        var available: Decimal? { expenses.map { balance + income - subscriptions - $0 } }

        var signal: SpendingSignal {
            let detail = expenses == nil
                ? "Record at least three ordinary expenses across a completed month to estimate remaining spending."
                : "Remaining expenses use the daily average of \(historyMonths) completed month(s), excluding subscription charges, and include at least your future-dated expenses."
            let result = available.map { "Estimated month-end balance: \($0.money(currency)). " } ?? ""
            return SpendingSignal(id: "forecast", kind: .projected, title: "End of month forecast", explanations: [
                result + "Recorded balance plus future-dated income, minus unpaid subscriptions and estimated remaining expenses. " + detail,
                result + detail + " The forecast adds expected income to your recorded balance and subtracts the remaining outgoings."
            ])
        }
    }

    static func forecast(_ transactions: [Transaction], subscriptions: [Subscription], scope: Scope, currency: String, now: Date, calendar: Calendar = .current) -> Forecast {
        let month = monthRange(for: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let rows = transactions.filter { $0.scope == scope && $0.currency == currency && Money.valid($0.amount, currency: currency) }
        // Date-only ledger entries on today's date are already recorded.
        let recorded = rows.filter { $0.date < tomorrow }
        let future = rows.filter { $0.date >= tomorrow && $0.date < month.upperBound }
        let linked = Set(subscriptions.flatMap { $0.payments.compactMap { $0.transaction?.cloudID } })
        func ordinary(_ row: Transaction) -> Bool { row.kind == .expense && row.source != .subscription && !linked.contains(row.cloudID) }
        let balance = recorded.reduce(Decimal.zero) { $0 + ($1.kind == .income ? $1.amount : -$1.amount) }
        let income = future.filter { $0.kind == .income }.reduce(Decimal.zero) { $0 + $1.amount }
        let unpaid = subscriptions.filter { $0.scope == scope && $0.currency == currency && $0.status == .active && Money.valid($0.amount, currency: currency) }.reduce(Decimal.zero) { sum, plan in
            let charges = Subscriptions.duePeriods(nextPaymentDate: Subscriptions.firstFutureDate(plan, now: month.lowerBound, calendar: calendar), anchorDay: plan.anchorDay,
                processed: Set(plan.payments.map(\.billingPeriod)), endDate: plan.endDate, trialEndsAt: plan.trialEndsAt,
                now: month.upperBound.addingTimeInterval(-1), calendar: calendar)
            return sum + Decimal(charges.filter { $0.date >= month.lowerBound }.count) * plan.amount
        }
        // Already-created future subscription transactions still need to be paid.
        let scheduled = unpaid + future.filter { $0.kind == .expense && !ordinary($0) }.reduce(Decimal.zero) { $0 + $1.amount }
        var baseline: [Transaction] = []
        var days = 0
        var months = 0
        if let first = recorded.map(\.date).min() {
            for offset in 1...3 {
                let start = calendar.date(byAdding: .month, value: -offset, to: month.lowerBound)!
                // Skip the first partial month of a newly started ledger.
                guard calendar.startOfDay(for: first) <= start else { continue }
                let range = monthRange(for: start, calendar: calendar)
                baseline += recorded.filter { ordinary($0) && range.contains($0.date) }
                days += calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day!
                months += 1
            }
        }
        var expenses: Decimal?
        // ponytail: daily historical average; add seasonal/category forecasting only with enough history to validate it.
        if days > 0 && baseline.count >= 3 {
            let daily = baseline.reduce(Decimal.zero) { $0 + $1.amount } / Decimal(days)
            let remainingDays = calendar.dateComponents([.day], from: today, to: month.upperBound).day!
            let spentToday = recorded.filter { ordinary($0) && $0.date >= today }.reduce(Decimal.zero) { $0 + $1.amount }
            let known = future.filter(ordinary).reduce(Decimal.zero) { $0 + $1.amount }
            expenses = max(known, daily * Decimal(max(0, remainingDays - 1)) + max(0, daily - spentToday))
        }
        return Forecast(currency: currency, balance: balance, income: income, subscriptions: scheduled, expenses: expenses, historyMonths: months)
    }

    enum LimitState {
        case ok, nearingLimit, atLimit

        /// Thresholds the PRD notifies on: 80% and 100% — plus an early-red
        /// escalation when 14 days or fewer remain in the month, since 80%
        /// spent with two weeks still to go is a worse sign than 80% on day 28.
        init(progress: Double, daysRemaining: Int = .max) {
            switch progress {
            case ..<0.8: self = .ok
            case ..<1.0: self = daysRemaining <= 14 ? .atLimit : .nearingLimit
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

    /// Rolling window of `days` whole days ending with today (inclusive).
    static func recentRange(days: Int, from now: Date = .now, calendar: Calendar = .current) -> Range<Date> {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let start = calendar.date(byAdding: .day, value: -days, to: end) ?? now
        return start..<end
    }

    static func daysRemaining(in range: Range<Date>, from now: Date = .now, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: now, to: range.upperBound).day ?? 0
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

    /// This month's expense total per category, categories with nothing spent
    /// omitted. `amount(in:)` (not the raw transaction amount) so a shared
    /// transaction only counts the caller's split.
    static func spendingByCategory(_ transactions: [Transaction], categories: [SpendingCategory], in range: Range<Date>, scope: Scope, currency: String = Money.code, kind: TransactionKind = .expense) -> [(category: SpendingCategory, total: Decimal)] {
        let month = transactions.filter { $0.kind == kind && $0.scope == scope && $0.currency == currency && range.contains($0.date) }
        return categories.compactMap { category in
            let total = month.reduce(Decimal.zero) { $0 + $1.amount(in: category) }
            return total > 0 ? (category, total) : nil
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

    // MARK: Family budget

    /// A shared transaction's author, with "written before family sync / by
    /// me" collapsed onto this device's own id in one place.
    static func author(of transaction: Transaction, meID: String) -> String {
        transaction.authorID.isEmpty ? meID : transaction.authorID
    }

    /// Who spent how much on the shared side this period. Personal scope is
    /// never included: it is nobody else's business by construction.
    static func spentByMember(_ transactions: [Transaction], in range: Range<Date>, currency: String = Money.code, meID: String) -> [String: Decimal] {
        transactions
            .filter { $0.kind == .expense && $0.scope == .shared && $0.currency == currency && range.contains($0.date) }
            .reduce(into: [String: Decimal]()) { totals, transaction in
                totals[author(of: transaction, meID: meID), default: 0] += transaction.amount
            }
    }

    /// Splits one shared expense between the members. Each share is rounded at
    /// the currency's own precision and the residual goes to the payer, so the
    /// shares always add back up to exactly the amount — a 50/50 split of 0.01
    /// is 0.01 and 0.00, never two half-cents.
    static func shares(of amount: Decimal, currency: String = Money.code, split: FamilyBudget, members: [String], payer: String) -> [String: Decimal] {
        guard !members.isEmpty else { return [:] }
        var result: [String: Decimal] = [:]
        for member in members {
            let percent = Decimal(split.percent(for: member, members: members))
            result[member] = rounded(amount * percent / 100, currency: currency)
        }
        let residual = amount - result.values.reduce(Decimal.zero, +)
        let target = members.contains(payer) ? payer : members.sorted()[0]
        result[target, default: 0] += residual
        return result
    }

    /// Positive means the family owes this member, negative means they owe it.
    /// Every balance in the map sums to zero, settlements included.
    static func balances(_ transactions: [Transaction], settlements: [Settlement], in range: Range<Date>, currency: String = Money.code, split: FamilyBudget, members: [String], meID: String) -> [String: Decimal] {
        var balance = members.reduce(into: [String: Decimal]()) { $0[$1] = 0 }
        for transaction in transactions where transaction.kind == .expense && transaction.scope == .shared
            && transaction.currency == currency && range.contains(transaction.date) {
            let payer = author(of: transaction, meID: meID)
            balance[payer, default: 0] += transaction.amount
            for (member, share) in shares(of: transaction.amount, currency: currency, split: split, members: members, payer: payer) {
                balance[member, default: 0] -= share
            }
        }
        for settlement in settlements where settlement.currency == currency && range.contains(settlement.date) {
            balance[settlement.fromMemberID.isEmpty ? meID : settlement.fromMemberID, default: 0] += settlement.amount
            balance[settlement.toMemberID.isEmpty ? meID : settlement.toMemberID, default: 0] -= settlement.amount
        }
        return balance
    }

    static func rounded(_ amount: Decimal, currency: String = Money.code) -> Decimal {
        var original = amount
        var result = Decimal.zero
        NSDecimalRound(&result, &original, Money.fractionDigits(currency), .plain)
        return result
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
    if case .atLimit = Budgeting.LimitState(progress: 0.8, daysRemaining: 14) {} else { assertionFailure("80% with 14 days left must escalate to red") }
    if case .nearingLimit = Budgeting.LimitState(progress: 0.8, daysRemaining: 15) {} else { assertionFailure("80% with more than 14 days left is still just a warning") }
    assert(Budgeting.daysRemaining(in: range, from: calendar.date(from: DateComponents(year: 2026, month: 9, day: 17))!, calendar: calendar) == 14, "14 days remain from the 17th to October 1st")

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

    let byCategory = Budgeting.spendingByCategory(all, categories: catalogue, in: range, scope: .personal)
    assert(byCategory.map(\.category.name) == ["Food"], "only categories with spending show up, in catalogue order")
    assert(byCategory.first?.total == 42, "the category total matches the personal-scope spend")
    assert(Budgeting.spendingByCategory(all, categories: catalogue, in: range, scope: .shared).first?.total == 35, "a shared transaction counts on the shared side, not personal")

    assert(Money.parse("42.499") == Decimal(string: "42.499"), "exact model decimal survives without float conversion")
    assert(Money.parse("-5") == nil && Money.parse("NaN") == nil && Money.parse("5abc") == nil && Money.parse("1.2.3") == nil, "malformed money is rejected, not partially parsed")
    assert(!Money.valid(Decimal(string: "1.001")!, currency: "USD"), "invalid currency precision requires review")
    assert(Money.valid(1, currency: "JPY") && !Money.valid(Decimal(string: "1.1")!, currency: "JPY"), "zero-decimal currencies stay exact")
    assert(DraftResolver.category(named: "food", in: catalogue) === food)
    assert(DraftResolver.category(named: "Unknown", in: catalogue) == nil, "unknown category requires review")
    let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))!
    assert(DraftResolver.date(DraftDate(offsetDays: -1, year: nil, month: nil, day: nil), now: today, calendar: calendar) == calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))!)
    assert(DraftResolver.date(DraftDate(offsetDays: nil, year: 2026, month: 2, day: 30), calendar: calendar) == nil, "invalid dates never normalize silently")
    let nowWithTime = calendar.date(byAdding: .hour, value: 14, to: today)!
    assert(DraftResolver.date(DraftDate(offsetDays: 0, year: nil, month: nil, day: nil), now: nowWithTime, calendar: calendar) == nowWithTime, "a same-day transaction keeps the real add time, not midnight")
    assert(DraftResolver.date(DraftDate(offsetDays: nil, year: 2026, month: 9, day: 3), now: nowWithTime, calendar: calendar) == nowWithTime, "an explicit y/m/d for today also keeps the real add time")
    // Receipt OCR has no "yesterday" to read, so a bare offset there is invented — it must not
    // silently backdate the scan; the caller falls back to now and asks the user to check the date.
    assert(DraftResolver.date(DraftDate(offsetDays: -1, year: nil, month: nil, day: nil), now: nowWithTime, calendar: calendar, allowRelative: false) == nil, "a receipt never resolves a relative day offset")
    assert(DraftResolver.date(DraftDate(offsetDays: -1, year: 2026, month: 9, day: 1), now: nowWithTime, calendar: calendar, allowRelative: false) == calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!, "a printed receipt date still wins over a stray offset")

    // The exact glyph is the locale's business — "$", "US$" and "USD" are all
    // correct answers. Only the shape is asserted.
    for code in ["USD", "AZN", "EUR"] {
        let symbol = Money.symbol(for: code)
        assert(!symbol.isEmpty, "\(code) must print something to put beside the field")
        assert(symbol.allSatisfy { !$0.isNumber && !$0.isWhitespace }, "\(code) symbol must carry no digits or spaces")
    }

    for code in Locale.commonISOCurrencyCodes where code != "CHF" {
        assert(Money.displaySymbol(for: code) != code, "\(code) needs a symbol in the picker, not its code twice")
    }

    assert(!Decimal(26.5).money("AZN").contains("AZN"), "a listed amount shows the glyph, not the code")
    assert(Decimal(26.5).money("AZN").contains(Money.displaySymbol(for: "AZN")), "and the glyph is the one the picker shows")
    assert(Decimal(26.5).money("CHF").contains("CHF"), "currencies without a glyph keep their code")

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

    let pricePlan = Subscription(name: "Price check", amount: 12, currency: "USD", nextPaymentDate: sept, category: food)
    let unused = Subscription(name: "Skip check", amount: 10, currency: "USD", nextPaymentDate: sept, paymentMode: .ask, category: food)
    assert(!Subscriptions.isPotentiallyUnused(unused, calendar: calendar))
    let skips = (1...4).map {
        SubscriptionPayment(billingPeriod: "2026-0\($0)", subscription: unused, transaction: nil, status: .skip, paymentMode: .ask)
    }
    unused.payments = Array(skips.prefix(2))
    assert(!Subscriptions.isPotentiallyUnused(unused, calendar: calendar), "below the threshold")
    unused.payments = [skips[2], skips[0], skips[1]]
    assert(Subscriptions.consecutiveSkips(unused, calendar: calendar) == 3)
    assert(Subscriptions.isPotentiallyUnused(unused, calendar: calendar), "exact threshold, independent of array order")
    assert(!Subscriptions.isPotentiallyUnused(unused, threshold: 4, calendar: calendar))
    assert(!Subscriptions.isPotentiallyUnused(unused, threshold: 0, calendar: calendar))
    unused.payments = skips
    assert(Subscriptions.consecutiveSkips(unused, calendar: calendar) == 4)
    skips[2].statusRaw = SubscriptionPayment.Status.paid.rawValue
    assert(!Subscriptions.isPotentiallyUnused(unused, calendar: calendar), "a paid payment with a deleted transaction breaks the run")
    skips[2].statusRaw = nil
    assert(!Subscriptions.isPotentiallyUnused(unused, calendar: calendar), "unknown legacy history is not a skip")
    skips[2].statusRaw = SubscriptionPayment.Status.skip.rawValue
    skips[2].paymentModeRaw = PaymentMode.autoAdd.rawValue
    assert(!Subscriptions.isPotentiallyUnused(unused, calendar: calendar), "other payment modes break the run")
    skips[2].paymentModeRaw = PaymentMode.ask.rawValue
    unused.paymentMode = .autoAdd
    assert(!Subscriptions.isPotentiallyUnused(unused, calendar: calendar))
    unused.paymentMode = .ask
    unused.payments = [skips[0], skips[2], skips[3]]
    assert(!Subscriptions.isPotentiallyUnused(unused, calendar: calendar), "missing months break consecutiveness")
    let duplicateSkip = SubscriptionPayment(billingPeriod: skips[2].billingPeriod, subscription: unused, transaction: nil, status: .skip, paymentMode: .ask)
    unused.payments = [skips[0], skips[1], skips[2], duplicateSkip]
    assert(!Subscriptions.isPotentiallyUnused(unused, calendar: calendar), "duplicate periods cannot inflate the run")

    assert(Subscriptions.annualCost(amount: 10, period: .weekly) == 520)
    assert(Subscriptions.annualCost(amount: 10, period: .monthly) == 120)
    assert(Subscriptions.annualCost(amount: 10, period: .quarterly) == 40)
    assert(Subscriptions.annualCost(amount: 10, period: .annual) == 10)
    assert(Subscriptions.annualCost(amount: 10, period: .weekly, interval: 2) == 260)
    assert(Subscriptions.annualCost(amount: 10, period: .monthly, interval: 3) == 40)
    assert(Subscriptions.annualCost(amount: Decimal(string: "9.99")!, period: .monthly) == Decimal(string: "119.88")!)
    assert(Subscriptions.annualCost(amount: 10, period: .annual, interval: 2) == 5)
    assert(Subscriptions.annualCost(amount: 10, period: .monthly, interval: 0) == 0)
    assert(Subscriptions.annualCost(amount: -1, period: .monthly) == 0)
    assert(Subscriptions.annualCost(amount: .nan, period: .monthly) == 0)
    assert(Subscriptions.annualCost(unused) == 120)
    let sharedPlan = Subscription(name: "Shared annual", amount: 100, currency: "USD", nextPaymentDate: sept, scope: .shared, category: food)
    let annualEntries: [(subscription: Subscription, period: Subscriptions.AnnualBillingPeriod, interval: Int)] = [
        (unused, .weekly, 1), (pricePlan, .monthly, 1), (sharedPlan, .annual, 1), (gym, .quarterly, 1)
    ]
    assert(Subscriptions.annualTotal(annualEntries, currency: "USD", now: sept, calendar: calendar) == 764)
    assert(Subscriptions.annualTotal(annualEntries + [(unused, .quarterly, 1)], currency: "USD", now: sept, calendar: calendar) == 804, "all four billing periods aggregate in Decimal")
    assert(Subscriptions.annualTotal(annualEntries, scope: .personal, currency: "USD", now: sept, calendar: calendar) == 664)
    assert(Subscriptions.annualTotal(annualEntries, scope: .shared, currency: "USD", now: sept, calendar: calendar) == 100)
    assert(Subscriptions.annualTotal(annualEntries, currency: "EUR", now: sept, calendar: calendar) == 0)
    sharedPlan.status = .paused
    assert(Subscriptions.annualTotal(annualEntries, currency: "USD", now: sept, calendar: calendar) == 664)
    sharedPlan.status = .active
    sharedPlan.endDate = jan31
    assert(Subscriptions.annualTotal(annualEntries, currency: "USD", now: sept, calendar: calendar) == 664)
    assert(Subscriptions.annualTotal([unused, pricePlan], currency: "USD", now: sept, calendar: calendar) == 264)
    assert(Subscriptions.priceChange(pricePlan, calendar: calendar) == nil, "empty history has no price change")
    let firstCharge = Transaction(amount: Decimal(string: "9.99")!, date: jan31, merchant: "Price check", category: food, currency: "USD")
    let secondCharge = Transaction(amount: Decimal(string: "12.49")!, date: feb, merchant: "Price check", category: food, currency: "USD")
    let firstPayment = SubscriptionPayment(billingPeriod: "2026-01", processedDate: sept, subscription: pricePlan, transaction: firstCharge)
    assert(Subscriptions.priceChange(pricePlan, calendar: calendar) == nil, "one payment has no comparison")
    let secondPayment = SubscriptionPayment(billingPeriod: "2026-02", processedDate: jan31, subscription: pricePlan, transaction: secondCharge)
    pricePlan.payments = [secondPayment, firstPayment]
    let increase = Subscriptions.priceChange(pricePlan, calendar: calendar)
    assert(increase?.delta == Decimal(string: "2.50") && increase?.direction == .increase, "9.99 to 12.49 increases by exactly 2.50")
    assert(increase?.currency == "USD" && increase?.periodDate == calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)), "billing month determines the period, regardless of array or processing order")

    secondCharge.amount = Decimal(string: "7.98")!
    let decrease = Subscriptions.priceChange(pricePlan, calendar: calendar)
    assert(decrease?.delta == Decimal(string: "-2.01") && decrease?.direction == .decrease, "9.99 to 7.98 decreases by exactly 2.01")
    secondCharge.amount = firstCharge.amount
    assert(Subscriptions.priceChange(pricePlan, calendar: calendar) == nil, "unchanged prices have no badge")
    secondCharge.amount = Decimal(string: "7.98")!
    secondCharge.currency = "EUR"
    assert(Subscriptions.priceChange(pricePlan, calendar: calendar) == nil, "different payment currencies are never compared")
    pricePlan.currency = "EUR"
    assert(Subscriptions.priceChange(pricePlan, calendar: calendar) == nil, "changing the schedule currency does not relabel old payments")
    secondCharge.currency = "USD"
    assert(Subscriptions.priceChange(pricePlan, calendar: calendar) == nil, "historical USD changes are hidden on an EUR schedule")
    pricePlan.currency = "USD"

    let thirdCharge = Transaction(amount: 15, date: mar, merchant: "Price check", category: food, currency: "USD")
    let thirdPayment = SubscriptionPayment(billingPeriod: "2026-03", subscription: pricePlan, transaction: thirdCharge)
    pricePlan.payments = [thirdPayment, firstPayment, secondPayment]
    secondCharge.currency = "EUR"
    assert(Subscriptions.priceChange(pricePlan, calendar: calendar) == nil, "USD to EUR to USD never bridges the middle payment")
    secondCharge.currency = "USD"
    assert(Subscriptions.priceChange(pricePlan, calendar: calendar)?.delta == Decimal(string: "7.02"), "only the latest adjacent pair is compared")
    secondPayment.transaction = nil
    assert(Subscriptions.priceChange(pricePlan, calendar: calendar) == nil, "skipped or deleted transactions never bridge a gap")
    secondPayment.transaction = secondCharge
    assert(Subscriptions.priceChange(gym, calendar: calendar) == nil, "another subscription does not inherit this history")
    thirdCharge.amount = .nan
    assert(Subscriptions.priceChange(pricePlan, calendar: calendar) == nil, "invalid stored amounts cannot produce a badge")

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

    let trialEnd = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 14))!
    assert(Subscriptions.nextDate(after: sept, anchorDay: 1, trialEndsAt: trialEnd, calendar: calendar) == trialEnd)
    let firstRenewal = Subscriptions.nextDate(after: trialEnd, anchorDay: 31, trialEndsAt: trialEnd, calendar: calendar)
    assert(firstRenewal == calendar.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 14))!)
    assert(calendar.component(.day, from: Subscriptions.nextDate(after: firstRenewal, anchorDay: 31, trialEndsAt: trialEnd, calendar: calendar)) == 31)
    assert(Subscriptions.duePeriods(nextPaymentDate: sept, anchorDay: 31, processed: [], trialEndsAt: trialEnd, now: trialEnd.addingTimeInterval(-1), calendar: calendar).isEmpty)
    assert(Subscriptions.duePeriods(nextPaymentDate: sept, anchorDay: 31, processed: [], trialEndsAt: trialEnd, now: trialEnd, calendar: calendar).map(\.date) == [trialEnd])
    do {
        let container = try ModelContainer(for: Subscription.self, SubscriptionPayment.self, Transaction.self, SpendingCategory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let trial = Subscription(name: "Trial", amount: 12, nextPaymentDate: sept, trialEndsAt: trialEnd,
            paymentMode: .ask, category: nil, calendar: calendar)
        context.insert(trial)
        assert(trial.nextPaymentDate == trialEnd && trial.anchorDay == 31)
        assert(netflix.trialEndsAt == nil, "existing subscriptions have no trial")
        assert(Subscriptions.firstFutureDate(trial, now: sept, calendar: calendar) == trialEnd)
        let fire = calendar.date(byAdding: .day, value: -2, to: trialEnd)!
        let request = Reminders.trialRequest(trial, now: sept, calendar: calendar)!
        let trigger = request.trigger as! UNCalendarNotificationTrigger
        assert(calendar.date(from: trigger.dateComponents) == fire && !trigger.repeats)
        assert(Reminders.trialRequest(trial, now: fire, calendar: calendar) == nil, "do not schedule past reminders")
        trial.status = .paused
        assert(Reminders.trialRequest(trial, now: sept, calendar: calendar) == nil)
        trial.status = .active
        trial.endDate = sept
        assert(Reminders.trialRequest(trial, now: sept, calendar: calendar) == nil)
        trial.endDate = nil
        // Boundary is in the past so the self-check cannot enqueue a test notification.
        trial.nextPaymentDate = sept
        trial.anchorDay = 1
        let beforeTrialEnd = try SubscriptionEngine.catchUp(in: context, now: trialEnd.addingTimeInterval(-1), calendar: calendar)
        assert(beforeTrialEnd.isEmpty && trial.nextPaymentDate == trialEnd && trial.anchorDay == 31)
        let due = try SubscriptionEngine.catchUp(in: context, now: trialEnd, calendar: calendar)
        assert(due.count == 1 && due[0].date == trialEnd)
        try SubscriptionEngine.skip(due[0], in: context, calendar: calendar)
        assert(trial.payments.first?.status == .skip && trial.payments.first?.paymentMode == .ask)
        assert(trial.nextPaymentDate == firstRenewal)
        let repeated = try SubscriptionEngine.catchUp(in: context, now: trialEnd, calendar: calendar)
        assert(repeated.isEmpty && trial.payments.count == 1)
    } catch { assertionFailure("Trial boundary self-check failed: \(error)") }

    // Transactions list window: 62 whole days ending with today.
    let recent = Budgeting.recentRange(days: 62, from: calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 15))!, calendar: calendar)
    assert(calendar.dateComponents([.day], from: recent.lowerBound, to: recent.upperBound).day == 62)
    assert(recent.contains(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 23))!))
    assert(recent.contains(calendar.date(from: DateComponents(year: 2026, month: 7, day: 21))!))
    assert(!recent.contains(calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 23))!))

    smartInsightsSelfCheck()
    aiFeaturesSelfCheck()
    merchantEmbeddingSelfCheck()
    categoryClassifierSelfCheck()
    // Family balances: what one person paid minus what they owed, and a
    // settlement for exactly that closes it.
    let meID = "me", partnerID = "partner"
    let members = [meID, partnerID]
    let month = Budgeting.monthRange(for: .now)
    let lunch = Transaction(amount: 80, date: .now, merchant: "Lunch", kind: .expense, scope: .shared, category: nil, currency: "AZN")
    let groceries = Transaction(amount: 20, date: .now, merchant: "Groceries", kind: .expense, scope: .shared, category: nil, currency: "AZN")
    groceries.authorID = partnerID
    let mine = Transaction(amount: 500, date: .now, merchant: "Solo", kind: .expense, scope: .personal, category: nil, currency: "AZN")
    assert(mine.authorID.isEmpty, "a personal transaction has nobody to attribute it to")

    let spent = Budgeting.spentByMember([lunch, groceries, mine], in: month, currency: "AZN", meID: meID)
    assert(spent[meID] == 80 && spent[partnerID] == 20, "personal spending never leaks into the family breakdown")

    let open = Budgeting.balances([lunch, groceries, mine], settlements: [], in: month, currency: "AZN", split: FamilyBudget(), members: members, meID: meID)
    assert(open[meID] == 30 && open[partnerID] == -30, "paying 80 of a 100 split evenly leaves 30 owed")
    assert(open.values.reduce(Decimal.zero, +) == 0, "balances always net to zero")

    let settled = Budgeting.balances(
        [lunch, groceries, mine],
        settlements: [Settlement(amount: 30, currency: "AZN", date: .now, fromMemberID: partnerID, toMemberID: meID)],
        in: month, currency: "AZN", split: FamilyBudget(), members: members, meID: meID
    )
    assert(settled[meID] == 0 && settled[partnerID] == 0, "settling the exact balance clears it")

    familySyncSelfCheck()

    let eta = Budgeting.projectedCompletion(remaining: 760, monthlyRate: 200, from: sept, calendar: calendar)
    assert(eta == calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!, "760 at 200 a month takes 4 months")
    assert(Budgeting.projectedCompletion(remaining: 100, monthlyRate: 0, from: sept, calendar: calendar) == nil, "no rate, no date")

    assert(AmountField.editable(0).isEmpty, "an empty amount field never seeds a leading zero to type around")
    assert(AmountField.editable(Decimal(string: "1250.75")!) == "1250.75", "an existing amount comes back editable, unrounded and ungrouped")

    let merchantSeeds = MerchantSeeds.load()
    assert(!merchantSeeds.isEmpty, "merchant-seeds.json must parse into at least one seed")
    let expenseCatalogue = SeedData.defaultCategories.map { SpendingCategory(name: $0.name, symbol: $0.symbol, tintHex: $0.tint, softHex: $0.soft, kind: .expense) }
    let resolvedSeeds = MerchantSeeds.resolved(merchantSeeds, categories: expenseCatalogue)
    assert(resolvedSeeds.count == merchantSeeds.count, "every merchant-seeds.json category must resolve against the default categories")

    // A live user's categories are user-editable and can legitimately drop one a
    // seed references (e.g. renaming/removing "Entertainment") — that must be
    // skipped, not asserted, or CategoryClassifier's rebuild crashes on launch.
    let missingOneCategory = expenseCatalogue.filter { $0.name != "Entertainment" }
    let lenientlyResolved = MerchantSeeds.resolved(merchantSeeds, categories: missingOneCategory, strict: false)
    assert(lenientlyResolved.count < merchantSeeds.count, "a category missing from the live catalogue must be skipped, not asserted, in non-strict mode")

    // Accounts: a balance is opening plus its own transactions, in its own
    // currency only, plus transfers in or out.
    let cash = Account(name: "Cash", kind: .cash, currency: "AZN", openingBalance: 100)
    let card = Account(name: "Card", kind: .card, currency: "AZN", openingBalance: 500)
    let dollars = Account(name: "Dollars", kind: .savings, currency: "USD", openingBalance: 0)
    let coffee = Transaction(amount: 10, date: .now, merchant: "Coffee", category: nil, currency: "AZN")
    coffee.account = cash
    let wage = Transaction(amount: 50, date: .now, merchant: "Wage", kind: .income, category: nil, currency: "AZN")
    wage.account = cash
    let abroad = Transaction(amount: 25, date: .now, merchant: "Abroad", category: nil, currency: "USD")
    abroad.account = cash
    let unassigned = Transaction(amount: 999, date: .now, merchant: "No account", category: nil, currency: "AZN")
    let accountLedger = [coffee, wage, abroad, unassigned]

    assert(Accounts.balance(cash, transactions: accountLedger, transfers: []) == 140, "100 opening, minus a 10 expense, plus 50 income")
    assert(Accounts.balance(dollars, transactions: accountLedger, transfers: []) == 0, "a USD transaction on an AZN account is never converted into its balance")
    assert(Accounts.balance(card, transactions: accountLedger, transfers: []) == 500, "a transaction with no account belongs to no balance")

    let moved = [Transfer(amount: 40, currency: "AZN", date: .now, from: card, to: cash)]
    assert(Accounts.balance(cash, transactions: accountLedger, transfers: moved) == 180, "a transfer in adds to the balance")
    assert(Accounts.balance(card, transactions: accountLedger, transfers: moved) == 460, "a transfer out takes from the balance")
    assert(Accounts.balance(cash, transactions: accountLedger, transfers: moved) + Accounts.balance(card, transactions: accountLedger, transfers: moved)
        == Accounts.balance(cash, transactions: accountLedger, transfers: []) + Accounts.balance(card, transactions: accountLedger, transfers: []),
        "moving your own money never changes how much of it there is")
    assert(Budgeting.spent(accountLedger, in: Budgeting.monthRange(for: .now), scope: .personal) == 1009,
        "accounts are an attribute, not a partition: spending totals still cover every account")

    assert(!Accounts.canTransfer(from: cash, to: cash, amount: 10), "an account cannot pay itself")
    assert(!Accounts.canTransfer(from: cash, to: dollars, amount: 10), "no conversion, so no cross-currency transfer")
    assert(!Accounts.canTransfer(from: cash, to: card, amount: 0), "a transfer needs a real amount")
    assert(Accounts.canTransfer(from: cash, to: card, amount: 10))

    // A recurring charge lands in the subscription's account, unless the price
    // is in a currency that account cannot hold.
    assert(Accounts.holder(cash, currency: "AZN") === cash, "a subscription charged in the account's own currency lands in it")
    assert(Accounts.holder(cash, currency: "USD") == nil, "a charge in another currency leaves no balance, it is never converted")
    assert(Accounts.holder(nil, currency: "AZN") == nil, "a subscription with no account still bills, unattributed")

    dollars.isArchived = true
    assert(Accounts.holder(dollars, currency: "USD") === dollars, "archiving hides an account from pickers, it does not stop charges already pointed at it")
    assert(Accounts.visible([cash, card, dollars]).count == 2, "an archived account leaves the pickers")
    assert(Accounts.nextSortIndex([cash, card, dollars]) == 1, "the next account sorts after the highest existing index")

    // Money tips: 31 of them, one per day, wrapping every 31 days.
    let tipsNewYear = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    assert(MoneyTips.all.count == 31, "the home card promises 31 tips")
    assert(MoneyTips.index(for: tipsNewYear, calendar: calendar) == 0)
    assert(MoneyTips.index(for: calendar.date(byAdding: .day, value: 1, to: tipsNewYear)!, calendar: calendar) == 1, "the tip changes every day")
    assert(MoneyTips.index(for: calendar.date(byAdding: .day, value: 31, to: tipsNewYear)!, calendar: calendar) == 0, "the rotation wraps after 31 days")

    // CSV / bank-statement import: cells first, then whole rows.
    // Decimals built from digits, never from a float literal: `Decimal(1234.56)`
    // carries binary-float noise and would never equal a parsed amount.
    let statementValue = { (text: String) in Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }
    assert(StatementImport.amount("-12.30") == statementValue("-12.30"), "a minus is money leaving")
    assert(StatementImport.amount("1 234,56") == statementValue("1234.56"), "a European statement groups with spaces and decimates with a comma")
    assert(StatementImport.amount("1,234.56") == statementValue("1234.56"))
    assert(StatementImport.amount("1,500") == 1500, "a lone separator with three digits behind it is a thousands mark")
    assert(StatementImport.amount("(45.00)") == -45, "accounting parentheses are a minus")
    assert(StatementImport.amount("45.00-") == -45, "so is a trailing minus")
    assert(StatementImport.amount("-12.30 USD") == statementValue("-12.30"), "a currency glued to the number is not part of it")
    assert(StatementImport.amount("") == nil && StatementImport.amount("pending") == nil, "an unreadable cell is skipped, never guessed at")

    let statementDay = calendar.date(from: DateComponents(year: 2026, month: 4, day: 3))!
    assert(StatementImport.date("2026-04-03", calendar: calendar) == statementDay)
    assert(StatementImport.date("03.04.2026", calendar: calendar) == statementDay)
    assert(StatementImport.date("03/04/2026", calendar: calendar) == statementDay, "a slashed date is read day first")
    assert(StatementImport.date("2026-04-03 13:02", calendar: calendar) == statementDay, "only the day survives, at midnight")
    assert(StatementImport.date("not a date", calendar: calendar) == nil)

    let statementCSV = "Date;Description;Amount;Currency\n03.04.2026;\"COFFEE; BAKU\";-4,50;AZN\n04.04.2026;Salary;1 200,00;AZN\n05.04.2026;broken;;AZN\n"
    assert(StatementImport.delimiter(statementCSV) == ";", "a European statement separates with semicolons")
    let statementFields = StatementImport.fields(statementCSV, delimiter: ";")
    assert(statementFields.count == 4, "three data rows plus the header, blank lines dropped")
    assert(statementFields[1][1] == "COFFEE; BAKU", "a quoted field keeps its delimiter")
    let statementMapping = StatementImport.guessMapping(header: statementFields[0])
    assert(statementMapping?.date == 0 && statementMapping?.merchant == 1 && statementMapping?.amount == 2 && statementMapping?.currency == 3)
    assert(StatementImport.guessMapping(header: ["foo", "bar"]) == nil, "a file with no recognisable header needs the user to map columns")
    let statementRows = StatementImport.rows(statementFields, mapping: statementMapping!, defaultCurrency: "AZN", skipFirst: true, calendar: calendar)
    assert(statementRows.count == 2, "the row with no amount is skipped")
    assert(statementRows[0].kind == .expense && statementRows[0].amount == statementValue("4.50") && statementRows[0].currency == "AZN")
    assert(statementRows[1].kind == .income && statementRows[1].amount == 1200, "a positive amount is money arriving")
    var forcedMapping = statementMapping!
    forcedMapping.sign = .allExpense
    assert(StatementImport.rows(statementFields, mapping: forcedMapping, defaultCurrency: "AZN", skipFirst: true, calendar: calendar).allSatisfy { $0.kind == .expense },
           "a Debit column is all spending whatever the sign")

    let statementTwin = Transaction(amount: statementValue("4.50"), date: calendar.date(byAdding: .hour, value: 9, to: statementRows[0].date)!,
                                    merchant: "coffee; baku", kind: .expense, scope: .personal, category: nil, currency: "AZN")
    assert(StatementImport.isDuplicate(statementRows[0], of: statementTwin, calendar: calendar), "the same charge on the same day is a re-import, whatever the time")
    assert(!StatementImport.isDuplicate(statementRows[1], of: statementTwin, calendar: calendar))
    statementTwin.amount = statementValue("4.51")
    assert(!StatementImport.isDuplicate(statementRows[0], of: statementTwin, calendar: calendar), "a different amount is a different charge")
}
#endif
