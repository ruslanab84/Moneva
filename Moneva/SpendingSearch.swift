import Foundation
import FoundationModels
import SwiftData

@Generable
enum SearchPeriod: String, CaseIterable { case all, today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, lastWeekend, custom }

@Generable
struct DraftedSearch {
    var period: SearchPeriod
    var start: DraftDate?
    var end: DraftDate?
    @Guide(description: "Exact existing category name or empty for any")
    var category: String
    var merchant: String
    @Guide(description: "Decimal lower bound or empty for none")
    var minimum: String
    @Guide(description: "Decimal upper bound or empty for none")
    var maximum: String
    @Guide(description: "ISO currency or empty for all currencies, which will be totaled separately")
    var currency: String
    @Guide(description: "personal or shared only if explicitly requested, otherwise empty")
    var scope: String
    @Guide(description: "expense, income or all")
    var kind: String
    var clarification: String
}

struct SpendingFilter {
    var range: Range<Date>?
    var category: SpendingCategory?
    var merchant = ""
    var minimum: Decimal?
    var maximum: Decimal?
    var currency: String?
    var scope: Scope
    var kind: TransactionKind? = .expense

    func matches(_ tx: Transaction) -> Bool {
        tx.scope == scope && (kind == nil || tx.kind == kind) &&
        (range == nil || range!.contains(tx.date)) && (currency == nil || tx.currency == currency) &&
        (category == nil || tx.amount(in: category) > 0) &&
        (merchant.isEmpty || CategoryLibrary.fold(tx.merchant).contains(CategoryLibrary.fold(merchant))) &&
        (minimum == nil || tx.amount >= minimum!) && (maximum == nil || tx.amount <= maximum!)
    }

    func amount(_ tx: Transaction) -> Decimal { category == nil ? tx.amount : tx.amount(in: category) }
    func results(_ transactions: [Transaction]) -> [Transaction] { transactions.filter(matches).sorted { $0.date > $1.date } }
}

enum SpendingSearch {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }

    static func range(_ period: SearchPeriod, start: DraftDate? = nil, end: DraftDate? = nil, now: Date = .now, calendar: Calendar = .current) throws -> Range<Date>? {
        let today = calendar.startOfDay(for: now)
        switch period {
        case .all: return nil
        case .today: return today..<calendar.date(byAdding: .day, value: 1, to: today)!
        case .yesterday: return calendar.date(byAdding: .day, value: -1, to: today)!..<today
        case .thisWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: today) else { throw Failure.invalid("Choose week dates manually.") }
            return week.start..<week.end
        case .lastWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: today),
                  let start = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start) else { throw Failure.invalid("Choose week dates manually.") }
            return start..<week.start
        case .thisMonth: return Budgeting.monthRange(for: now, calendar: calendar)
        case .lastMonth: return Budgeting.monthRange(for: calendar.date(byAdding: .month, value: -1, to: now)!, calendar: calendar)
        case .lastWeekend:
            guard let weekend = calendar.nextWeekend(startingAfter: today, direction: .backward) else { throw Failure.invalid("Choose weekend dates manually.") }
            return weekend.start..<weekend.end
        case .custom:
            guard let start, let end, let first = DraftResolver.date(start, now: now, calendar: calendar),
                  let last = DraftResolver.date(end, now: now, calendar: calendar), first <= last,
                  let exclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else { throw Failure.invalid("Choose a valid start and end date.") }
            return calendar.startOfDay(for: first)..<exclusive
        }
    }

    /// The caller supplies the authorized partition. Model output cannot widen access.
    static func resolve(_ draft: DraftedSearch, categories: [SpendingCategory], scope: Scope, now: Date = .now, calendar: Calendar = .current) throws -> SpendingFilter {
        guard draft.clarification.isEmpty else { throw Failure.invalid(draft.clarification) }
        guard draft.scope.isEmpty || draft.scope == scope.rawValue else { throw Failure.invalid("Switch to the requested scope in Transactions, then search again.") }
        let category = DraftResolver.category(named: draft.category, in: CategoryLibrary.visible(categories, scope: scope))
        guard draft.category.isEmpty || category != nil else { throw Failure.invalid("Choose an existing category in the filters.") }
        let currency = draft.currency.uppercased()
        guard currency.isEmpty || Money.pickerCodes.contains(currency) else { throw Failure.invalid("Choose a valid currency.") }
        let minimum = draft.minimum.isEmpty ? nil : Money.parse(draft.minimum)
        let maximum = draft.maximum.isEmpty ? nil : Money.parse(draft.maximum)
        guard draft.minimum.isEmpty || minimum != nil, draft.maximum.isEmpty || maximum != nil,
              minimum == nil || maximum == nil || minimum! <= maximum! else { throw Failure.invalid("Check the amount range.") }
        guard ["expense", "income", "all"].contains(draft.kind) else { throw Failure.invalid("Choose expense or income in the filters.") }
        return SpendingFilter(range: try range(draft.period, start: draft.start, end: draft.end, now: now, calendar: calendar), category: category,
            merchant: draft.merchant, minimum: minimum, maximum: maximum, currency: currency.isEmpty ? nil : currency,
            scope: scope, kind: TransactionKind(rawValue: draft.kind))
    }
}

struct SpendingFact: Identifiable {
    let id: Int
    let text: String
    let transactions: [Transaction]
    var category: SpendingCategory?
}

enum SpendingReport {
    static func facts(transactions: [Transaction], categories: [SpendingCategory], budgets: [Budget], subscriptions: [Subscription], scope: Scope, now: Date = .now, calendar: Calendar = .current) -> [SpendingFact] {
        let current = Budgeting.monthRange(for: now, calendar: calendar)
        let previous = Budgeting.monthRange(for: calendar.date(byAdding: .month, value: -1, to: now)!, calendar: calendar)
        let history = transactions.filter { $0.scope == scope && $0.kind == .expense && $0.date <= now }
        let hasPriorHistory = history.contains(where: { previous.contains($0.date) })
        var facts: [SpendingFact] = []
        func add(_ text: String, _ source: [Transaction], category: SpendingCategory? = nil) { facts.append(SpendingFact(id: facts.count, text: text, transactions: source, category: category)) }
        if hasPriorHistory {
            add("This month is incomplete. Comparisons below use this month so far and the full previous month; unrecorded spending is unknown.", [])
            if !history.contains(where: { $0.date < previous.lowerBound }) {
                add("History before the comparison period is insufficient to establish complete coverage. Missing transactions are not evidence of zero spending.", [])
            }
        }
        for currency in Set(history.map(\.currency) + subscriptions.filter { $0.scope == scope }.map(\.currency)).sorted() {
            let month = history.filter { $0.currency == currency && current.contains($0.date) }
            let prior = history.filter { $0.currency == currency && previous.contains($0.date) }
            let total = month.reduce(Decimal.zero) { $0 + $1.amount }
            if prior.isEmpty {
                add("Recorded spending this month so far: \(total.money(currency)).", month)
            } else {
                add("Recorded spending this month so far: \(total.money(currency)). Previous calendar month: \(prior.reduce(Decimal.zero) { $0 + $1.amount }.money(currency)).", month + prior)
            }
            for category in categories {
                let used = month.reduce(Decimal.zero) { $0 + $1.amount(in: category) }
                let before = prior.reduce(Decimal.zero) { $0 + $1.amount(in: category) }
                guard used > 0 || before > 0 else { continue }
                if prior.isEmpty {
                    add("\(category.name): \(used.money(currency)) this month so far.", month.filter { $0.amount(in: category) > 0 }, category: category)
                } else {
                    let difference = used - before
                    add("\(category.name): \(used.money(currency)) this month so far versus \(before.money(currency)) in the previous month; \(difference >= 0 ? "increase" : "decrease") of \(abs(difference).money(currency)). The difference reflects the linked recorded purchases, not a known change in habits or prices.", (month + prior).filter { $0.amount(in: category) > 0 }, category: category)
                }
            }
            if let budget = budgets.first(where: { $0.scope == scope && $0.monthStart == current.lowerBound && ($0.currency ?? Money.code) == currency }) {
                add("Budget: \(total.money(currency)) used of \(budget.total.money(currency)); \(max(budget.total - total, 0).money(currency)) remaining.", month)
                for limit in budget.limits {
                    let used = month.reduce(Decimal.zero) { $0 + $1.amount(in: limit.category) }
                    add("\(limit.category?.name ?? String(localized: "Uncategorised")) budget: \(used.money(currency)) used of \(limit.amount.money(currency)).", month.filter { $0.amount(in: limit.category) > 0 }, category: limit.category)
                }
            }
        }
        for line in SubscriptionDigest.lines(for: subscriptions.filter { $0.scope == scope }, now: now, calendar: calendar) {
            add(line, history.filter { $0.source == .subscription })
        }
        return facts
    }
}
