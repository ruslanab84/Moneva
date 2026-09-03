import Foundation
import SwiftData
import SwiftUI

enum Scope: String, Codable, CaseIterable, Identifiable {
    case personal, shared
    var id: String { rawValue }
    var title: String { self == .personal ? "Personal" : "Shared" }
    var symbol: String { self == .personal ? "person" : "person.2" }
}

enum TransactionKind: String, Codable, CaseIterable, Identifiable {
    case expense, income
    var id: String { rawValue }
    var title: String { self == .expense ? "Expense" : "Income" }
}

/// How a transaction got in. Voice and receipt drafts land here only after the
/// user confirms them.
enum EntrySource: String, Codable {
    case manual, voice, receipt
}

@Model
final class SpendingCategory {
    var name: String = ""
    var symbol: String = "circle"
    var tintHex: String = "78746A"
    var softHex: String = "E4E2DB"
    var monthlyLimit: Decimal?
    var isBuiltIn: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction] = []

    init(name: String, symbol: String, tintHex: String, softHex: String, monthlyLimit: Decimal? = nil, isBuiltIn: Bool = false) {
        self.name = name
        self.symbol = symbol
        self.tintHex = tintHex
        self.softHex = softHex
        self.monthlyLimit = monthlyLimit
        self.isBuiltIn = isBuiltIn
    }

    var tint: Color { Color(hex: tintHex) }
    var soft: Color { Color(hex: softHex) }
}

@Model
final class Transaction {
    var amount: Decimal = Decimal.zero
    var currency: String = "AZN"
    var date: Date = Date.now
    var merchant: String = ""
    var note: String = ""
    var kind: TransactionKind = TransactionKind.expense
    var scope: Scope = Scope.personal
    var source: EntrySource = EntrySource.manual
    var category: SpendingCategory?

    init(amount: Decimal, date: Date = .now, merchant: String, note: String = "", kind: TransactionKind = .expense, scope: Scope = .personal, source: EntrySource = .manual, category: SpendingCategory?, currency: String = "AZN") {
        self.amount = amount
        self.date = date
        self.merchant = merchant
        self.note = note
        self.kind = kind
        self.scope = scope
        self.source = source
        self.category = category
        self.currency = currency
    }

    /// Signed value for sums: expenses pull the month down, income lifts it.
    var signedAmount: Decimal { kind == .expense ? -amount : amount }
}

@Model
final class Budget {
    /// First instant of the budgeted month, in the user's calendar.
    var monthStart: Date = Date.now
    var total: Decimal = Decimal.zero
    var scope: Scope = Scope.personal

    @Relationship(deleteRule: .cascade, inverse: \BudgetLimit.budget)
    var limits: [BudgetLimit] = []

    init(monthStart: Date, total: Decimal, scope: Scope = .personal) {
        self.monthStart = monthStart
        self.total = total
        self.scope = scope
    }
}

@Model
final class BudgetLimit {
    var amount: Decimal = Decimal.zero
    var category: SpendingCategory?
    var budget: Budget?

    init(amount: Decimal, category: SpendingCategory?) {
        self.amount = amount
        self.category = category
    }
}

@Model
final class Goal {
    var name: String = ""
    var symbol: String = "flag"
    var tintHex: String = "7A5B86"
    var target: Decimal = Decimal.zero
    var saved: Decimal = Decimal.zero
    var deadline: Date?
    var scope: Scope = Scope.personal
    var createdAt: Date = Date.now

    init(name: String, symbol: String, tintHex: String, target: Decimal, saved: Decimal = 0, deadline: Date? = nil, scope: Scope = .personal) {
        self.name = name
        self.symbol = symbol
        self.tintHex = tintHex
        self.target = target
        self.saved = saved
        self.deadline = deadline
        self.scope = scope
    }

    var remaining: Decimal { max(target - saved, 0) }
}

