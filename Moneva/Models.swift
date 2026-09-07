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
    case manual, voice, text, receipt, subscription
}

@Model
final class SpendingCategory {
    var name: String = ""
    var symbol: String = "circle"
    var tintHex: String = "78746A"
    var softHex: String = "E4E2DB"
    var monthlyLimit: Decimal?
    var isBuiltIn: Bool = false
    /// Archived categories leave the picker but keep every transaction they
    /// ever held. Nothing is deleted.
    var isArchived: Bool = false
    /// Stored as a raw string. SwiftData cannot fill an enum column that rows
    /// written before this property existed never had, and reading the empty
    /// value force-casts and crashes.
    var scopeRaw: String?
    /// Which side of the ledger this category belongs to. Same optional-raw
    /// treatment as `scopeRaw`: rows written before it existed read as expense.
    var kindRaw: String?
    /// Manual order in the picker. Ties fall back to name.
    var sortIndex: Int = 0

    var scope: Scope {
        get { scopeRaw.flatMap(Scope.init(rawValue:)) ?? .personal }
        set { scopeRaw = newValue.rawValue }
    }

    var kind: TransactionKind {
        get { kindRaw.flatMap(TransactionKind.init(rawValue:)) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction] = []

    init(name: String, symbol: String, tintHex: String, softHex: String, monthlyLimit: Decimal? = nil, isBuiltIn: Bool = false, scope: Scope = .personal, kind: TransactionKind = .expense, sortIndex: Int = 0) {
        self.name = name
        self.symbol = symbol
        self.tintHex = tintHex
        self.softHex = softHex
        self.monthlyLimit = monthlyLimit
        self.isBuiltIn = isBuiltIn
        self.scopeRaw = scope.rawValue
        self.kindRaw = kind.rawValue
        self.sortIndex = sortIndex
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

    init(amount: Decimal, date: Date = .now, merchant: String, note: String = "", kind: TransactionKind = .expense, scope: Scope = .personal, source: EntrySource = .manual, category: SpendingCategory?, currency: String = Money.code) {
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

    var draftID: String?
    @Attribute(.externalStorage) var receiptImage: Data?
    var receiptItems: Data?
    @Relationship(deleteRule: .cascade, inverse: \TransactionAllocation.transaction)
    var allocations: [TransactionAllocation] = []

    func amount(in category: SpendingCategory?) -> Decimal {
        if allocations.isEmpty { return self.category?.persistentModelID == category?.persistentModelID ? amount : 0 }
        return allocations.filter { $0.category?.persistentModelID == category?.persistentModelID }.reduce(0) { $0 + $1.amount }
    }

    /// Signed value for sums: expenses pull the month down, income lifts it.
    var signedAmount: Decimal { kind == .expense ? -amount : amount }
}

@Model
final class Budget {
    /// First instant of the budgeted month, in the user's calendar.
    var monthStart: Date = Date.now
    var currency: String?
    var total: Decimal = Decimal.zero
    var scope: Scope = Scope.personal

    @Relationship(deleteRule: .cascade, inverse: \BudgetLimit.budget)
    var limits: [BudgetLimit] = []

    init(monthStart: Date, total: Decimal, scope: Scope = .personal) {
        self.monthStart = monthStart
        self.total = total
        self.currency = Money.code
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


enum BillingFrequency: String, Codable, CaseIterable, Identifiable {
    /// Monthly is the whole MVP. The stored raw value leaves room for more.
    case monthly
    var id: String { rawValue }
    var title: String { "Every month" }
}

enum SubscriptionStatus: String, Codable, CaseIterable, Identifiable {
    case active, paused
    var id: String { rawValue }
    var title: String { self == .active ? "Active" : "Paused" }
}

/// What happens on the payment date. `ask` never writes on its own — it queues
/// a confirmation the user answers.
enum PaymentMode: String, Codable, CaseIterable, Identifiable {
    case autoAdd, ask
    var id: String { rawValue }
    var title: String { self == .autoAdd ? "Auto-add transaction" : "Ask before adding" }
}

@Model
final class Subscription {
    /// Stable across launches and devices, so a scheduled reminder can still
    /// find its subscription. `persistentModelID` is not a string.
    var id: UUID = UUID()
    var name: String = ""
    var amount: Decimal = Decimal.zero
    var currency: String = "AZN"
    var frequency: BillingFrequency = BillingFrequency.monthly
    var nextPaymentDate: Date = Date.now
    /// Last date a charge may land on — a loan or any fixed-term plan. nil is
    /// open-ended, which is what every subscription written before this was.
    var endDate: Date?
    /// Optional storage lets subscriptions from older stores migrate without backfilling.
    var trialEndsAt: Date? = nil
    /// Day of the month the charge lands on, kept separately so a short month
    /// never drags the date backwards for good.
    var anchorDay: Int = 1
    /// Days before the payment to remind, or nil for no reminder.
    var reminderDays: Int?
    var paymentMode: PaymentMode = PaymentMode.autoAdd
    var note: String = ""
    var scope: Scope = Scope.personal
    var status: SubscriptionStatus = SubscriptionStatus.active
    var createdAt: Date = Date.now
    var category: SpendingCategory?

    @Relationship(deleteRule: .cascade, inverse: \SubscriptionPayment.subscription)
    var payments: [SubscriptionPayment] = []

    init(
        name: String,
        amount: Decimal,
        currency: String = Money.code,
        nextPaymentDate: Date,
        endDate: Date? = nil,
        trialEndsAt: Date? = nil,
        reminderDays: Int? = nil,
        paymentMode: PaymentMode = .autoAdd,
        note: String = "",
        scope: Scope = .personal,
        category: SpendingCategory?,
        calendar: Calendar = .current
    ) {
        self.name = name
        self.amount = amount
        self.currency = currency
        self.nextPaymentDate = trialEndsAt ?? nextPaymentDate
        self.endDate = endDate
        self.trialEndsAt = trialEndsAt
        self.anchorDay = calendar.component(.day, from: trialEndsAt ?? nextPaymentDate)
        self.reminderDays = reminderDays
        self.paymentMode = paymentMode
        self.note = note
        self.scope = scope
        self.category = category
    }

    var draftID: String?

    var monthlyCost: Decimal { status == .active ? amount : 0 }
}

/// One charge that has already been handled. Its billing period is what stops
/// a subscription being charged twice for the same month.
@Model
final class SubscriptionPayment {
    /// "2026-09" — the month the charge belongs to, not when it was processed.
    var billingPeriod: String = ""
    var processedDate: Date = Date.now
    var subscription: Subscription?
    /// Nullified when the user deletes the transaction; the payment stays as
    /// the record that this period was already handled.
    @Relationship(deleteRule: .nullify)
    var transaction: Transaction?

    init(billingPeriod: String, processedDate: Date = .now, subscription: Subscription?, transaction: Transaction?) {
        self.billingPeriod = billingPeriod
        self.processedDate = processedDate
        self.subscription = subscription
        self.transaction = transaction
    }
}

@Model
final class TransactionAllocation {
    var amount: Decimal = Decimal.zero
    var category: SpendingCategory?
    var transaction: Transaction?
    init(amount: Decimal, category: SpendingCategory?) {
        self.amount = amount
        self.category = category
    }
}

@Model
final class MerchantCategoryRule {
    var merchant: String = ""
    var scopeRaw: String = "personal"
    var category: SpendingCategory?
    init(merchant: String, scope: Scope, category: SpendingCategory) {
        self.merchant = merchant
        self.scopeRaw = scope.rawValue
        self.category = category
    }
}
