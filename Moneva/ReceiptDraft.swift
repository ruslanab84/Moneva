import Foundation
import FoundationModels
import SwiftData

@Generable
enum ReceiptLineKind: String, Codable, CaseIterable { case item, tax, discount }

@Generable
struct DraftedReceiptLine {
    var name: String
    var kind: ReceiptLineKind
    @Guide(description: "Printed positive line amount, NOT unit price. Empty if unreadable; do not multiply.")
    var amount: String
    @Guide(description: "Printed quantity, empty if not readable")
    var quantity: String
    @Guide(description: "Printed unit price, empty if not readable")
    var unitPrice: String
    @Guide(description: "True only for an informational tax/discount already included in item amounts. Never count twice.")
    var alreadyIncluded: Bool
    var category: String
    var uncertainty: String
}

@Generable
struct DraftedReceipt {
    var merchant: String
    var date: DraftDate
    var currency: String
    @Guide(description: "Printed final paid total, decimal digits; empty if unclear. Never use subtotal, tendered cash or change.")
    var total: String
    @Guide(description: "Available items, taxes and discounts; empty when extraction fails", .maximumCount(80))
    var items: [DraftedReceiptLine]
    var clarification: String
}

struct ReceiptItem: Identifiable {
    var id = UUID()
    var name = ""
    var kind: ReceiptLineKind = .item
    var amount: Decimal = 0
    var quantity = ""
    var unitPrice = ""
    var alreadyIncluded = false
    var category: SpendingCategory?
    var uncertainty = ""
    var contribution: Decimal { alreadyIncluded ? 0 : (kind == .discount ? -amount : amount) }
}

struct ReceiptAllocation: Identifiable {
    var category: SpendingCategory?
    var amount: Decimal
    var id: String { category.map { String(describing: $0.persistentModelID) } ?? "uncategorised" }
}

struct SavedReceiptItem: Codable {
    var name: String
    var kind: ReceiptLineKind
    var amount: Decimal
    var quantity: String
    var unitPrice: String
    var alreadyIncluded: Bool
    var category: String?
}

enum ReceiptMath {
    static func allocations(_ items: [ReceiptItem]) -> [ReceiptAllocation] {
        let groups = Dictionary(grouping: items.filter { !$0.alreadyIncluded }) { $0.category?.persistentModelID }
        return groups.values.map { group in
            ReceiptAllocation(category: group.first?.category, amount: group.reduce(0) { $0 + $1.contribution })
        }.sorted { ($0.category?.name ?? "") < ($1.category?.name ?? "") }
    }

    static func reconciled(_ items: [ReceiptItem], total: Decimal, currency: String, scope: Scope) -> Bool {
        let allocations = allocations(items)
        return Money.valid(total, currency: currency) && !allocations.isEmpty &&
            items.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && Money.valid($0.amount, currency: currency) && ($0.alreadyIncluded || CategoryLibrary.isSelectable($0.category, scope: scope)) } &&
            allocations.allSatisfy { $0.amount >= 0 } && allocations.reduce(0) { $0 + $1.amount } == total
    }

    static func duplicates(_ draft: TransactionDraft, in transactions: [Transaction], calendar: Calendar = .current) -> [Transaction] {
        transactions.filter {
            $0.kind == .expense && $0.scope == draft.scope && $0.currency == draft.currency && $0.amount == draft.amount &&
            calendar.isDate($0.date, inSameDayAs: draft.date) &&
            (CategoryLibrary.fold(draft.merchant).isEmpty || CategoryLibrary.fold($0.merchant).isEmpty || CategoryLibrary.fold($0.merchant) == CategoryLibrary.fold(draft.merchant))
        }
    }
}
