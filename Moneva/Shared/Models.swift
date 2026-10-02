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

    /// Finer labels under this category. Totals, budgets and charts still key
    /// off the category; a subcategory only describes a transaction further.
    @Relationship(deleteRule: .cascade, inverse: \Subcategory.category)
    var subcategories: [Subcategory] = []

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

/// A label under one category (Food → Lunch). Scope and kind come from the
/// parent, so a subcategory can never sit on the wrong side of the ledger.
@Model
final class Subcategory {
    var name: String = ""
    var sortIndex: Int = 0
    var isArchived: Bool = false
    var category: SpendingCategory?
    @Relationship(deleteRule: .nullify, inverse: \Transaction.subcategory)
    var transactions: [Transaction] = []

    init(name: String, category: SpendingCategory?, sortIndex: Int = 0) {
        self.name = name
        self.category = category
        self.sortIndex = sortIndex
    }
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
    /// Optional and additive: older rows have none, and no total reads it.
    var subcategory: Subcategory?

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
    /// Which account the money moved through. Optional and additive: rows
    /// written before accounts existed simply have none, and nothing that
    /// totals money requires it.
    var account: Account?
    @Attribute(.externalStorage) var receiptImage: Data?
    var receiptItems: Data?
    @Relationship(deleteRule: .cascade, inverse: \TransactionAllocation.transaction)
    var allocations: [TransactionAllocation] = []

    /// Stable across devices, unlike `persistentModelID` — doubles as the
    /// CKRecord name for shared-scope family sync. Default-initialized, so
    /// this is a safe additive column, not the `SpendingCategory.scopeRaw`
    /// enum-backfill landmine.
    var cloudID: UUID = UUID()
    /// Archived CKRecord system fields (change tag included), cached so a
    /// later edit round-trips through CloudKit instead of conflicting with
    /// itself. nil means this transaction has never been synced.
    var ckSystemFields: Data?
    /// CloudKit user record name of whoever entered this. Empty means "me, or
    /// written before family sync existed" — same safe additive-default shape
    /// as `cloudID`, not the `scopeRaw` enum-backfill landmine. Personal-scope
    /// rows keep it empty: there is nobody to attribute them to.
    var authorID: String = ""

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

    /// See `Transaction.ckSystemFields`. Only shared-scope budgets ever sync.
    var ckSystemFields: Data?
    /// `FamilyBudget` as JSON: who splits this budget in what proportion, and
    /// each member's personal ceiling inside the shared total.
    /// ponytail: the whole family side of a budget is one JSON column and one
    /// CKRecord, last-write-wins as a unit. Split it into real columns and
    /// child records if a family ever grows past two people, or if partners
    /// report clobbered edits.
    var familyJSON: String?

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
    /// Which account the charge leaves from. Optional and additive, exactly
    /// like `Transaction.account`: subscriptions written before accounts
    /// existed simply have none, and nothing that totals money requires it.
    var account: Account?
    /// Same optional-raw-string treatment as SpendingCategory.kindRaw: subscriptions
    /// written before this existed read as expense.
    var kindRaw: String? = nil

    var kind: TransactionKind {
        get { kindRaw.flatMap(TransactionKind.init(rawValue:)) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

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
        kind: TransactionKind = .expense,
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
        self.kindRaw = kind.rawValue
    }

    var draftID: String?

    var monthlyCost: Decimal { status == .active ? amount : 0 }
}

/// One charge that has already been handled. Its billing period is what stops
/// a subscription being charged twice for the same month.
@Model
final class SubscriptionPayment {
    enum Status: String { case paid, skip }

    /// Unknown for legacy rows: a deleted transaction is not evidence of a skip.
    var statusRaw: String? = nil
    var paymentModeRaw: String? = nil
    var status: Status? { statusRaw.flatMap(Status.init(rawValue:)) }
    var paymentMode: PaymentMode? { paymentModeRaw.flatMap(PaymentMode.init(rawValue:)) }
    /// "2026-09" — the month the charge belongs to, not when it was processed.
    var billingPeriod: String = ""
    var processedDate: Date = Date.now
    var subscription: Subscription?
    /// Nullified when the user deletes the transaction; the payment stays as
    /// the record that this period was already handled.
    @Relationship(deleteRule: .nullify)
    var transaction: Transaction?

    init(billingPeriod: String, processedDate: Date = .now, subscription: Subscription?, transaction: Transaction?, status: Status? = nil, paymentMode: PaymentMode? = nil) {
        self.billingPeriod = billingPeriod
        self.processedDate = processedDate
        self.subscription = subscription
        self.transaction = transaction
        self.statusRaw = status?.rawValue
        self.paymentModeRaw = paymentMode?.rawValue
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

/// One participant of the family share, cached locally so a transaction can
/// show a name without a CloudKit round-trip. Never synced — each device
/// rebuilds it from `CKShare.participants`.
@Model
final class FamilyMember {
    /// CloudKit user record name. Matches `Transaction.authorID`.
    var memberID: String = ""
    var name: String = ""
    var isMe: Bool = false

    init(memberID: String, name: String, isMe: Bool) {
        self.memberID = memberID
        self.name = name
        self.isMe = isMe
    }
}

/// Money moved between family members to clear a balance. Deliberately not a
/// `Transaction`: paying your partner back is not spending, and keeping it out
/// of that type means no existing total, chart, budget or AI tool has to learn
/// to exclude it.
@Model
final class Settlement {
    var cloudID: UUID = UUID()
    var amount: Decimal = Decimal.zero
    var currency: String = "AZN"
    var date: Date = Date.now
    /// Who paid.
    var fromMemberID: String = ""
    /// Who was paid.
    var toMemberID: String = ""
    var ckSystemFields: Data?

    init(amount: Decimal, currency: String = Money.code, date: Date = .now, fromMemberID: String, toMemberID: String) {
        self.amount = amount
        self.currency = currency
        self.date = date
        self.fromMemberID = fromMemberID
        self.toMemberID = toMemberID
    }
}

enum AccountKind: String, Codable, CaseIterable, Identifiable {
    case cash, card, bank, savings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cash: return "Cash"
        case .card: return "Card"
        case .bank: return "Bank"
        case .savings: return "Savings"
        }
    }
    var symbol: String {
        switch self {
        case .cash: return "banknote"
        case .card: return "creditcard"
        case .bank: return "building.columns"
        case .savings: return "lock.square"
        }
    }
}

/// Where the money actually sits. Deliberately *not* a partition like `Scope`:
/// every existing total, chart, budget and AI tool keeps summing across all
/// accounts. Only the accounts screen filters by one.
@Model
final class Account {
    var name: String = ""
    /// Stored as a raw string for the same reason as `SpendingCategory.scopeRaw`:
    /// SwiftData cannot fill an enum column rows written before it existed never had.
    var kindRaw: String?
    var tintHex: String = "78746A"
    /// The account's own currency. A transaction in any other currency is not
    /// part of this balance — the app never converts money.
    var currency: String = "AZN"
    /// What was on the account the day it was added here.
    var openingBalance: Decimal = Decimal.zero
    /// Archived accounts leave the picker but keep every transaction they held.
    var isArchived: Bool = false
    var sortIndex: Int = 0
    var createdAt: Date = Date.now

    var kind: AccountKind {
        get { kindRaw.flatMap(AccountKind.init(rawValue:)) ?? .cash }
        set { kindRaw = newValue.rawValue }
    }

    @Relationship(deleteRule: .nullify, inverse: \Transaction.account)
    var transactions: [Transaction] = []

    init(name: String, kind: AccountKind = .cash, tintHex: String = "78746A", currency: String = Money.code, openingBalance: Decimal = 0, sortIndex: Int = 0) {
        self.name = name
        self.kindRaw = kind.rawValue
        self.tintHex = tintHex
        self.currency = currency
        self.openingBalance = openingBalance
        self.sortIndex = sortIndex
    }

    var symbol: String { kind.symbol }
    var tint: Color { Color(hex: tintHex) }
}

/// Money moved between your own accounts. Deliberately not a `Transaction`, for
/// the same reason as `Settlement`: moving your own money is not spending, and
/// keeping it out of that type means no existing total, chart, budget or AI
/// tool has to learn to exclude it.
@Model
final class Transfer {
    var amount: Decimal = Decimal.zero
    var currency: String = "AZN"
    var date: Date = Date.now
    var note: String = ""
    @Relationship(deleteRule: .nullify) var from: Account?
    @Relationship(deleteRule: .nullify) var to: Account?

    init(amount: Decimal, currency: String = Money.code, date: Date = .now, note: String = "", from: Account?, to: Account?) {
        self.amount = amount
        self.currency = currency
        self.date = date
        self.note = note
        self.from = from
        self.to = to
    }
}
