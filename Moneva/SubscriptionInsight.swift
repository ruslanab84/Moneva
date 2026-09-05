import Foundation
import FoundationModels
import SwiftData

@Generable
struct DraftedMonthlySubscription {
    var name: String
    var amount: String
    var currency: String
    var nextPayment: DraftDate
    var category: String
    var clarification: String
}

struct DetectedSubscription: Identifiable {
    var id = UUID()
    var name: String
    var amount: Decimal
    var nextPaymentDate: Date
    var category: SpendingCategory?
    var scope: Scope
    var reason: String
    var currency = Money.code
}

enum SubscriptionResolver {
    static func nextDate(dayOfMonth: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        let candidate = Subscriptions.dateInMonth(of: now, anchorDay: dayOfMonth, like: now, calendar: calendar)
        guard candidate <= now else { return candidate }
        return Subscriptions.nextDate(after: candidate, anchorDay: dayOfMonth, calendar: calendar)
    }

    static func resolveInput(_ value: DraftedMonthlySubscription, categories: [SpendingCategory], scope: Scope, input: String, now: Date = .now) -> DetectedSubscription {
        let currency = value.currency.uppercased()
        let date = DraftResolver.date(value.nextPayment, now: now)
        return DetectedSubscription(name: DraftResolver.grounded(value.name, in: input), amount: Money.parse(value.amount) ?? 0, nextPaymentDate: date ?? now,
            category: DraftResolver.category(named: value.category, in: categories), scope: scope,
            reason: [value.clarification, date == nil ? "Choose the next payment date." : "", Money.pickerCodes.contains(currency) ? "" : "Choose the billing currency."].filter { !$0.isEmpty }.joined(separator: "\n"),
            currency: Money.pickerCodes.contains(currency) ? currency : Money.code)
    }
}

enum SubscriptionDigest {
    static func lines(for subscriptions: [Subscription], calendar: Calendar = .current) -> [String] {
        let active = subscriptions.filter { $0.status == .active }
        var lines = ["\(active.count) active subscriptions. These are schedules, not charges made by Moneva."]
        for currency in Set(active.map(\.currency)).sorted() {
            lines.append("Scheduled monthly cost: \(Subscriptions.monthlyTotal(active, currency: currency).money(currency)).")
        }
        for subscription in active.sorted(by: { $0.amount > $1.amount }) {
            var line = "\(subscription.name): \(subscription.amount.money(subscription.currency)) monthly, next payment \(subscription.nextPaymentDate.formatted(date: .abbreviated, time: .omitted))."
            if let change = priceChange(subscription) { line += " Last two recorded payments: \(change.old.money(subscription.currency)), then \(change.new.money(subscription.currency))." }
            lines.append(line)
        }
        lines.append("Payment history cannot tell whether a subscription is being used. Paused schedules are excluded from future costs.")
        return lines
    }

    static func priceChange(_ subscription: Subscription) -> (old: Decimal, new: Decimal)? {
        let charges = subscription.payments.compactMap(\.transaction).sorted { $0.date < $1.date }
        guard charges.count >= 2 else { return nil }
        let last = charges.suffix(2)
        guard last.allSatisfy({ $0.currency == subscription.currency }), let old = last.first?.amount, let new = last.last?.amount, old != new else { return nil }
        return (old, new)
    }
}

@Generable
struct SelectedFacts {
    @Guide(description: "IDs of supplied facts relevant to the question. Empty if the facts cannot answer it. Never invent IDs.", .maximumCount(8))
    var ids: [Int]
}

@MainActor
@Observable
final class SubscriptionAdvisor {
    enum Phase { case idle, working, ready, failed(String) }
    private(set) var phase: Phase = .idle
    private(set) var detected: [DetectedSubscription] = []
    private(set) var answer = ""
    private(set) var answerScope: Scope?
    private var ignored: Set<String> = []
    static var unavailableReason: String? { TransactionDrafter.unavailableReason }

    func detect(from transactions: [Transaction], categories: [SpendingCategory], existing: [Subscription], scope: Scope) async {
        if case .working = phase { return }
        await performDetection(transactions, categories: categories, existing: existing, scope: scope)
    }

    private func performDetection(_ transactions: [Transaction], categories: [SpendingCategory], existing: [Subscription], scope: Scope) async {
        detected = []
        guard Self.unavailableReason == nil else { return }
        let candidates = Self.candidates(transactions, categories: categories, existing: existing, scope: scope)
        guard !candidates.isEmpty else { phase = .idle; return }
        phase = .working
        do {
            let result = try await OnDeviceAI.generate(SelectedFacts.self,
                instructions: "Select candidate IDs that plausibly represent monthly subscription services. Exclude ordinary groceries and variable purchases. These are suggestions only.",
                data: candidates.enumerated().map { "\($0.offset): \($0.element.name), \($0.element.amount.money($0.element.currency)) monthly." }.joined(separator: "\n"))
            detected = Array(Set(result.ids)).sorted().filter { candidates.indices.contains($0) }.map { candidates[$0] }.filter { !ignored.contains(Self.key($0)) }
            phase = .ready
        } catch { phase = .failed("Could not inspect recurring expenses. Manual subscription entry is available.") }
    }

    func ask(_ question: String, subscriptions: [Subscription], scope: Scope) async {
        if case .working = phase { return }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        phase = .working
        answer = ""
        answerScope = scope
        let facts = SubscriptionDigest.lines(for: subscriptions.filter { $0.scope == scope })
        do {
            let result = try await OnDeviceAI.generate(SelectedFacts.self, instructions: "Select supplied facts answering the question. Do not infer usage from payment history.",
                data: "Question: \(question)\nFacts:\n" + facts.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n"))
            answer = Array(Set(result.ids)).sorted().filter { facts.indices.contains($0) }.map { facts[$0] }.joined(separator: "\n\n")
            if answer.isEmpty { answer = "The stored schedules do not provide enough information to answer that." }
            phase = .ready
        } catch { phase = .failed(error.localizedDescription) }
    }

    func dismissDetection(_ item: DetectedSubscription) {
        ignored.insert(Self.key(item))
        detected.removeAll { $0.id == item.id }
    }

    private static func key(_ item: DetectedSubscription) -> String { "\(item.scope.rawValue)|\(item.currency)|\(CategoryLibrary.fold(item.name))" }

    // ponytail: exact recurring amounts across distinct months; widen tolerance only with evidence that variable bills need it.
    static func candidates(_ transactions: [Transaction], categories: [SpendingCategory], existing: [Subscription], scope: Scope, now: Date = .now, calendar: Calendar = .current) -> [DetectedSubscription] {
        let expenses = transactions.filter { $0.kind == .expense && $0.scope == scope && $0.date <= now && !$0.merchant.isEmpty }
        let groups = Dictionary(grouping: expenses) { "\($0.currency)|\(CategoryLibrary.fold($0.merchant))" }
        return groups.values.compactMap { group in
            let sorted = group.sorted { $0.date > $1.date }
            guard sorted.count >= 2, let latest = sorted.first,
                  !existing.contains(where: { $0.scope == scope && $0.currency == latest.currency && CategoryLibrary.fold($0.name) == CategoryLibrary.fold(latest.merchant) }) else { return nil }
            let previous = sorted[1]
            let month1 = Budgeting.monthStart(for: previous.date, calendar: calendar)
            let month2 = Budgeting.monthStart(for: latest.date, calendar: calendar)
            guard calendar.dateComponents([.month], from: month1, to: month2).month == 1,
                  latest.amount == previous.amount,
                  abs(calendar.component(.day, from: latest.date) - calendar.component(.day, from: previous.date)) <= 3 else { return nil }
            return DetectedSubscription(name: latest.merchant, amount: latest.amount,
                nextPaymentDate: SubscriptionResolver.nextDate(dayOfMonth: calendar.component(.day, from: latest.date), now: now, calendar: calendar),
                category: CategoryLibrary.isSelectable(latest.category, scope: scope) ? latest.category : nil,
                scope: scope, reason: "Matching payments in consecutive months. Review before creating a schedule.", currency: latest.currency)
        }.sorted { $0.name < $1.name }
    }
}
