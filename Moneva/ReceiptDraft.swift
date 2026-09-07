import Foundation
import FoundationModels
import SwiftData

@Generable
enum ReceiptLineKind: String, Codable, CaseIterable { case item, tax, discount }

@Generable
struct DraftedReceipt {
    var merchant: String
    var date: DraftDate
    var currency: String
    @Guide(description: "Printed final paid total, decimal digits; empty if unclear. Never use subtotal, tendered cash or change.")
    var total: String
    @Guide(description: "One existing category for the whole receipt, empty if unclear")
    var category: String
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
    var sourceText = ""
    var ocrConfidence: Float?
    var categoryConfidence: ReceiptCategoryConfidence = .uncertain
    var reviewed = false
    var contribution: Decimal { alreadyIncluded ? 0 : (kind == .discount ? -amount : amount) }
}

struct ReceiptAllocation: Identifiable {
    var category: SpendingCategory?
    var amount: Decimal
    var id: String { category.map { String(describing: $0.persistentModelID) } ?? "uncategorised" }
}

enum ReceiptMode: String, CaseIterable, Identifiable {
    case single, split
    var id: String { rawValue }
    var title: String { self == .single ? "Single category" : "Split by category" }
}

/// Editable value state; persistence uses the existing transaction and allocations.
struct Receipt {
    var draft = TransactionDraft(source: .receipt)
    var mode: ReceiptMode = .single
    var items: [ReceiptItem] = []

    var breakdown: [CategoryBreakdown] { ReceiptMath.breakdown(items, total: draft.amount) }
    var remaining: Decimal { draft.amount - items.reduce(0) { $0 + $1.contribution } }
    var canSave: Bool {
        if mode == .single { return draft.canSave }
        return draft.reviewed && items.allSatisfy(\.reviewed) &&
            ReceiptMath.reconciled(items, total: draft.amount, currency: draft.currency, scope: draft.scope)
    }

    func save(in context: ModelContext, image: Data?) throws {
        guard canSave else { throw DraftStore.Failure.invalid }
        var savedDraft = draft
        let allocations = mode == .split ? ReceiptMath.allocations(items).filter { $0.amount > 0 } : []
        if mode == .split {
            savedDraft.category = allocations.first?.category
            savedDraft.rememberCategory = false
        }
        let details = mode == .split ? try JSONEncoder().encode(items.map {
            SavedReceiptItem(name: $0.name, kind: $0.kind, amount: $0.amount,
                quantity: $0.quantity, unitPrice: $0.unitPrice, alreadyIncluded: $0.alreadyIncluded,
                category: $0.category?.name)
        }) : nil
        try DraftStore.save([savedDraft], in: context, allocations: allocations, receiptImage: image, receiptItems: details)
    }
}

struct CategoryBreakdown: Identifiable {
    var allocation: ReceiptAllocation
    var items: [ReceiptItem]
    /// A ratio, formatted as a percentage only at the UI boundary.
    var fraction: Decimal?
    var id: String { allocation.id }
}

@Generable
enum ReceiptCategoryConfidence: String { case likely, uncertain }

@Generable
struct ReceiptLineSuggestion {
    var lineID: Int
    @Guide(description: "ID from supplied categories; nil if ambiguous or no category fits")
    var categoryID: Int?
    var confidence: ReceiptCategoryConfidence
    var kind: ReceiptLineKind
    @Guide(description: "True for totals, payment/change, subtotals, or tax/discount already included in item amounts")
    var alreadyIncluded: Bool
    @Guide(description: "Short reason, especially for abbreviations, ambiguous categories or included adjustments")
    var reason: String
}

@Generable
struct ReceiptLineSuggestions {
    @Guide(description: "One result for each supplied line ID", .maximumCount(8))
    var lines: [ReceiptLineSuggestion]
}

enum ReceiptCategorizer {
    static func suggest(_ items: [ReceiptItem], categories: [SpendingCategory]) async throws -> [ReceiptItem] {
        var result = items
        // Small independent sessions keep long receipts within the model's context window.
        for start in stride(from: 0, to: items.count, by: 8) {
            let indices = Array(start..<min(start + 8, items.count))
            let names = categories.enumerated().map { "\($0.offset): \($0.element.name)" }.joined(separator: "\n")
            let lines = indices.map { "\($0): \(items[$0].sourceText)" }.joined(separator: "\n")
            let suggestions = try await OnDeviceAI.generate(ReceiptLineSuggestions.self,
                instructions: "Classify receipt rows individually by product purpose using only supplied category IDs. Do not classify an entire supermarket as food. Use common product abbreviations only when the meaning is clear; opaque SKUs and conflicting categories require nil and uncertain. Examples: milk -> food, dish detergent -> household, electricity bill -> utilities, MISC 001 -> uncertain. If the required category is absent, return nil and uncertain, never force a nearby category. Electricity is not transport unless vehicle charging is explicitly stated. Identify item, tax and discount. Totals, subtotals, tendered cash, card payments and change are informational and alreadyIncluded. Do not add included VAT again. Never invent rows, prices, quantities or categories. Return every supplied line ID exactly once.",
                data: "Categories:\n\(names)\nReceipt rows:\n\(lines)")
            apply(suggestions.lines, to: &result, indices: indices, categories: categories)
        }
        return result
    }

    static func apply(_ suggestions: [ReceiptLineSuggestion], to items: inout [ReceiptItem], indices: [Int], categories: [SpendingCategory]) {
        for index in indices {
            let matches = suggestions.filter { $0.lineID == index }
            guard matches.count == 1, let suggestion = matches.first else { continue }
            items[index].category = suggestion.categoryID.flatMap { categories.indices.contains($0) ? categories[$0] : nil }
            items[index].categoryConfidence = items[index].category == nil ? .uncertain : suggestion.confidence
            items[index].kind = suggestion.kind
            items[index].alreadyIncluded = items[index].alreadyIncluded || suggestion.alreadyIncluded
            items[index].uncertainty = String(suggestion.reason.prefix(240))
        }
    }
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
    static func breakdown(_ items: [ReceiptItem], total: Decimal) -> [CategoryBreakdown] {
        allocations(items).map { allocation in
            CategoryBreakdown(allocation: allocation,
                items: items.filter { !$0.alreadyIncluded && $0.category?.persistentModelID == allocation.category?.persistentModelID },
                fraction: !total.isNaN && total > 0 && !allocation.amount.isNaN ? allocation.amount / total : nil)
        }
    }
    static func allocations(_ items: [ReceiptItem]) -> [ReceiptAllocation] {
        let groups = Dictionary(grouping: items.filter { !$0.alreadyIncluded }) { $0.category?.persistentModelID }
        return groups.values.map { group in
            ReceiptAllocation(category: group.first?.category, amount: group.reduce(0) { $0 + $1.contribution })
        }.sorted { ($0.category?.name ?? "") < ($1.category?.name ?? "") }
    }

    static func reconciled(_ items: [ReceiptItem], total: Decimal, currency: String, scope: Scope) -> Bool {
        let allocations = allocations(items)
        return Money.valid(total, currency: currency) && !allocations.isEmpty &&
            items.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (Money.valid($0.amount, currency: currency) || ($0.alreadyIncluded && $0.amount == 0)) && ($0.alreadyIncluded || CategoryLibrary.isSelectable($0.category, scope: scope)) } &&
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
