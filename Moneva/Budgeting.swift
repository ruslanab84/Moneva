import Foundation
import SwiftUI
#if DEBUG
import SwiftData
import UserNotifications
#endif

/// Granularity for browsing transactions — the list groups by day either way,
/// this only decides how much of the calendar is in view at once.
enum TransactionPeriod: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }
}

/// Every number the app shows is computed here, in Swift — never by a model.
enum Budgeting {
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

    static func dayRange(for date: Date, calendar: Calendar = .current) -> Range<Date> {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? date
        return start..<end
    }

    static func weekRange(for date: Date, calendar: Calendar = .current) -> Range<Date> {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? date
        return start..<end
    }

    static func range(for period: TransactionPeriod, anchor: Date, calendar: Calendar = .current) -> Range<Date> {
        switch period {
        case .day: return dayRange(for: anchor, calendar: calendar)
        case .week: return weekRange(for: anchor, calendar: calendar)
        case .month: return monthRange(for: anchor, calendar: calendar)
        }
    }

    /// Steps the anchor date one period at a time — a stride the calendar owns,
    /// so week boundaries follow the user's locale instead of a fixed 7 days.
    static func shift(_ period: TransactionPeriod, by amount: Int, from anchor: Date, calendar: Calendar = .current) -> Date {
        let component: Calendar.Component
        switch period {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        return calendar.date(byAdding: component, value: amount, to: anchor) ?? anchor
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
    static func spendingByCategory(_ transactions: [Transaction], categories: [SpendingCategory], in range: Range<Date>, scope: Scope, currency: String = Money.code) -> [(category: SpendingCategory, total: Decimal)] {
        let month = transactions.filter { $0.kind == .expense && $0.scope == scope && $0.currency == currency && range.contains($0.date) }
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

    let sept17 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 17))!
    let dayRange = Budgeting.dayRange(for: sept17, calendar: calendar)
    assert(dayRange.lowerBound == sept17 && dayRange.upperBound == calendar.date(byAdding: .day, value: 1, to: sept17)!, "a day range is exactly one day")
    let weekRange = Budgeting.weekRange(for: sept17, calendar: calendar)
    assert(calendar.dateComponents([.day], from: weekRange.lowerBound, to: weekRange.upperBound).day == 7, "a week range spans 7 days")
    assert(weekRange.contains(sept17), "the anchor date falls inside its own week range")
    assert(Budgeting.range(for: .month, anchor: sept17, calendar: calendar) == range, "the month period matches monthRange")
    assert(calendar.component(.day, from: Budgeting.shift(.day, by: 1, from: sept17, calendar: calendar)) == 18, "shifting a day moves the anchor forward one day")
    assert(calendar.component(.month, from: Budgeting.shift(.month, by: -1, from: sept17, calendar: calendar)) == 8, "shifting a month back lands in August")

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
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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

    aiFeaturesSelfCheck()

    let eta = Budgeting.projectedCompletion(remaining: 760, monthlyRate: 200, from: sept, calendar: calendar)
    assert(eta == calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!, "760 at 200 a month takes 4 months")
    assert(Budgeting.projectedCompletion(remaining: 100, monthlyRate: 0, from: sept, calendar: calendar) == nil, "no rate, no date")

    assert(AmountField.editable(0).isEmpty, "an empty amount field never seeds a leading zero to type around")
    assert(AmountField.editable(Decimal(string: "1250.75")!) == "1250.75", "an existing amount comes back editable, unrounded and ungrouped")
}
#endif
