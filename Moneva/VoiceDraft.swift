import Foundation
import FoundationModels
import SwiftData

/// What the on-device model is allowed to produce. It never writes anything —
/// `DraftResolver` turns this into app types and Swift does the saving.
@Generable
enum DraftKind: String {
    case expense, income
}

@Generable
struct DraftedTransaction {
    @Guide(description: "Whether money left the account (expense) or arrived (income)")
    var kind: DraftKind

    @Guide(description: "The amount of money as a plain number, no currency symbol", .minimum(0.0))
    var amount: Double

    @Guide(description: "The shop, person or source that was named. Empty string if none was said.")
    var merchant: String

    @Guide(description: "The closest category name from the list of categories given in the instructions")
    var category: String

    @Guide(description: "How many days ago this happened: 0 for today, 1 for yesterday", .range(0...31))
    var daysAgo: Int

    @Guide(description: "Anything else said that is worth keeping. Empty string if nothing.")
    var note: String
}

/// Resolved, app-typed draft. Still not saved — the user confirms first.
struct TransactionDraft {
    var kind: TransactionKind
    var amount: Decimal
    var merchant: String
    var note: String
    var date: Date
    var category: SpendingCategory?
    var scope: Scope
}

/// Pure translation from model output to app values. Everything the model can
/// get wrong is clamped here, not downstream.
enum DraftResolver {
    /// Money never comes out of the model as a Decimal, so it round-trips
    /// through two fraction digits — the precision a receipt has anyway.
    static func amount(_ value: Double) -> Decimal {
        guard value.isFinite, value > 0 else { return 0 }
        return Decimal(string: String(format: "%.2f", value), locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    static func date(daysAgo: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -min(max(daysAgo, 0), 31), to: now) ?? now
    }

    /// Match on the name the model returned; fall back to Other rather than
    /// leaving an expense uncategorised.
    static func category(named name: String, in categories: [SpendingCategory]) -> SpendingCategory? {
        let wanted = fold(name)
        return categories.first { fold($0.name) == wanted }
            ?? categories.first { fold($0.name) == "other" }
            ?? categories.first
    }

    static func resolve(_ drafted: DraftedTransaction, categories: [SpendingCategory], scope: Scope, now: Date = .now) -> TransactionDraft {
        let kind: TransactionKind = drafted.kind == .income ? .income : .expense
        return TransactionDraft(
            kind: kind,
            amount: amount(drafted.amount),
            merchant: drafted.merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            note: drafted.note.trimmingCharacters(in: .whitespacesAndNewlines),
            date: date(daysAgo: drafted.daysAgo, now: now),
            category: kind == .expense ? category(named: drafted.category, in: categories) : nil,
            scope: scope
        )
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

/// Wraps one `LanguageModelSession`. One request at a time, availability
/// checked before every entry point.
@MainActor
@Observable
final class TransactionDrafter {
    enum Phase {
        case idle, drafting, ready(DraftedTransaction), failed(String)
    }

    private(set) var phase: Phase = .idle
    private var session: LanguageModelSession?

    /// Why the feature is off, or nil when it is on.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return SystemLanguageModel.default.supportsLocale(.current)
                ? nil
                : "Apple Intelligence does not support your language yet."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to draft by voice."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready. Try again shortly."
        case .unavailable(.deviceNotEligible):
            return "This iPhone cannot run Apple Intelligence."
        case .unavailable:
            return "On-device drafting is unavailable right now."
        }
    }

    func prewarm(categories: [SpendingCategory]) {
        guard Self.unavailableReason == nil else { return }
        let session = makeSession(categories: categories)
        self.session = session
        session.prewarm()
    }

    func draft(from transcript: String, categories: [SpendingCategory]) async {
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        if let reason = Self.unavailableReason {
            phase = .failed(reason)
            return
        }
        let session = session ?? makeSession(categories: categories)
        self.session = session
        guard !session.isResponding else { return }

        phase = .drafting
        do {
            let response = try await session.respond(
                to: "Sentence: \(spoken)",
                generating: DraftedTransaction.self
            )
            phase = .ready(response.content)
        } catch {
            phase = .failed("Could not read that as a transaction. Try again or add it by hand.")
        }
    }

    func reset() {
        phase = .idle
        session = nil
    }

    /// Category names are app data, so they belong in the instructions. The
    /// spoken sentence is untrusted and stays in the prompt.
    private func makeSession(categories: [SpendingCategory]) -> LanguageModelSession {
        let names = categories.map(\.name).joined(separator: ", ")
        return LanguageModelSession {
            "You turn one spoken sentence about money into a single transaction draft."
            "Choose the category from exactly this list: \(names)."
            "Money going out is an expense. Salary, refunds and gifts received are income."
            "Only use amounts, names and days that the sentence actually says. Never invent them."
        }
    }
}
