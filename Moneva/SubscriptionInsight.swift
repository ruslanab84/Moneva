import Foundation
import FoundationModels
import SwiftData

/// What the model may propose for a recurring payment. It never creates one —
/// the user confirms every field first.
@Generable
struct DraftedSubscription {
    @Guide(description: "The service name as written on the transactions")
    var name: String

    @Guide(description: "The amount charged each month, as a plain number", .minimum(0.0))
    var amount: Double

    @Guide(description: "The day of the month the charge lands on", .range(1...31))
    var dayOfMonth: Int

    @Guide(description: "The closest category name from the list in the instructions")
    var category: String

    @Guide(description: "One short sentence saying why this looks recurring")
    var reason: String
}

@Generable
struct DraftedSubscriptions {
    @Guide(description: "Only charges that repeat on a similar day each month. Empty when nothing repeats.")
    var items: [DraftedSubscription]
}

/// A proposal resolved into app types. Still only a proposal.
struct DetectedSubscription: Identifiable {
    let id = UUID()
    var name: String
    var amount: Decimal
    var nextPaymentDate: Date
    var category: SpendingCategory?
    var scope: Scope
    var reason: String
}

enum SubscriptionResolver {
    /// The model gives a day of the month; Swift turns it into the next real
    /// date, clamped to months that are too short for it.
    static func nextDate(dayOfMonth: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        let candidate = Subscriptions.dateInMonth(of: now, anchorDay: dayOfMonth, like: now, calendar: calendar)
        guard candidate <= now else { return candidate }
        return Subscriptions.nextDate(after: candidate, anchorDay: dayOfMonth, calendar: calendar)
    }

    /// Drops anything already tracked, so the same service is never proposed twice.
    static func resolve(
        _ drafts: [DraftedSubscription],
        categories: [SpendingCategory],
        existing: [Subscription],
        scope: Scope,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [DetectedSubscription] {
        let taken = Set(existing.map { fold($0.name) })
        return drafts.compactMap { draft in
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = DraftResolver.amount(draft.amount)
            guard !name.isEmpty, amount > 0, !taken.contains(fold(name)) else { return nil }
            return DetectedSubscription(
                name: name,
                amount: amount,
                nextPaymentDate: nextDate(dayOfMonth: draft.dayOfMonth, now: now, calendar: calendar),
                category: DraftResolver.category(named: draft.category, in: categories),
                scope: scope,
                reason: draft.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

/// Every number in here is computed in Swift and handed to the model as fact.
/// The model only ever phrases the answer.
enum SubscriptionDigest {
    static func lines(for subscriptions: [Subscription], calendar: Calendar = .current) -> [String] {
        let active = subscriptions.filter { $0.status == .active }
        var lines = [
            "Active subscriptions: \(active.count).",
            "Total charged each month: \(Subscriptions.monthlyTotal(active).money()).",
        ]
        for subscription in active.sorted(by: { $0.amount > $1.amount }) {
            var line = "\(subscription.name): \(subscription.amount.money(subscription.currency)) a month"
            line += ", category \(subscription.category?.name ?? "none")"
            line += ", next on \(subscription.nextPaymentDate.formatted(date: .abbreviated, time: .omitted))"
            if let change = priceChange(subscription) { line += ", the price went from \(change.old.money(subscription.currency)) to \(change.new.money(subscription.currency))" }
            lines.append(line + ".")
        }
        let paused = subscriptions.filter { $0.status == .paused }
        if !paused.isEmpty { lines.append("Paused: \(paused.map(\.name).joined(separator: ", ")).") }
        return lines
    }

    /// Compares the last two charges that actually went through.
    static func priceChange(_ subscription: Subscription) -> (old: Decimal, new: Decimal)? {
        let amounts = subscription.payments
            .compactMap { payment -> (Date, Decimal)? in
                guard let transaction = payment.transaction else { return nil }
                return (payment.processedDate, transaction.amount)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        guard amounts.count >= 2 else { return nil }
        let old = amounts[amounts.count - 2]
        let new = amounts[amounts.count - 1]
        return old == new ? nil : (old, new)
    }
}

/// Finds candidate subscriptions in past spending, and answers questions about
/// the ones already tracked. Both are read-only.
@MainActor
@Observable
final class SubscriptionAdvisor {
    enum Phase {
        case idle, working, ready, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var detected: [DetectedSubscription] = []
    private(set) var answer = ""

    static var unavailableReason: String? { TransactionDrafter.unavailableReason }

    /// Proposals only. Nothing is created until the user taps Add it.
    func detect(from transactions: [Transaction], categories: [SpendingCategory], existing: [Subscription], scope: Scope) async {
        guard Self.unavailableReason == nil else { return }
        let candidates = Self.repeatingCandidates(transactions)
        guard !candidates.isEmpty else {
            detected = []
            phase = .idle
            return
        }

        phase = .working
        let names = categories.map(\.name).joined(separator: ", ")
        let session = LanguageModelSession {
            "You look at a list of past card charges and point out the ones that repeat every month."
            "A charge repeats when the same merchant is charged a similar amount on a similar day in more than one month."
            "Ignore groceries, restaurants and anything that varies a lot."
            "Choose the category from exactly this list: \(names)."
            "Never invent a merchant or an amount that is not in the list."
        }
        do {
            let response = try await session.respond(to: "Charges:\n\(candidates)", generating: DraftedSubscriptions.self)
            detected = SubscriptionResolver.resolve(response.content.items, categories: categories, existing: existing, scope: scope)
            phase = .ready
        } catch {
            phase = .failed("Could not look through your history just now.")
        }
    }

    func ask(_ question: String, subscriptions: [Subscription]) async {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        if let reason = Self.unavailableReason {
            phase = .failed(reason)
            return
        }

        phase = .working
        answer = ""
        let facts = SubscriptionDigest.lines(for: subscriptions).joined(separator: "\n")
        let session = LanguageModelSession {
            "You answer questions about the recurring payments a person already tracks."
            "These are the only facts you have, and every number in them is already correct:"
            facts
            "Answer in two or three short sentences. Never do arithmetic the facts do not already state, and never invent a service."
        }
        do {
            let stream = session.streamResponse(to: asked)
            for try await snapshot in stream { answer = snapshot.content }
            phase = .ready
        } catch {
            phase = .failed("Could not answer that just now.")
        }
    }

    func dismissDetection(_ item: DetectedSubscription) {
        detected.removeAll { $0.id == item.id }
    }

    /// Only merchants seen in more than one month are worth the model's time,
    /// and only their own text is sent.
    static func repeatingCandidates(_ transactions: [Transaction], calendar: Calendar = .current) -> String {
        let expenses = transactions.filter { $0.kind == .expense && !$0.merchant.isEmpty }
        let byMerchant = Dictionary(grouping: expenses) {
            $0.merchant.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }
        let lines = byMerchant.values
            .filter { group in Set(group.map { Subscriptions.billingPeriod(for: $0.date, calendar: calendar) }).count > 1 }
            .flatMap { $0 }
            .sorted { $0.date < $1.date }
            .map { "\($0.merchant) — \($0.amount.money($0.currency)) on \($0.date.formatted(date: .abbreviated, time: .omitted))" }
        return lines.joined(separator: "\n")
    }
}
