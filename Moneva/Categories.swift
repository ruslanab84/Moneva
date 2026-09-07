import Foundation
import SwiftUI
import FoundationModels

/// The icons and colours a custom category can be built from. SF Symbols only —
/// they carry accessibility labels, scale with Dynamic Type and render right in
/// both themes, which emoji do none of.
enum CategoryLibrary {
    static let symbolGroups: [(name: String, symbols: [String])] = [
        ("Everyday", ["fork.knife", "cart", "bag", "takeoutbag.and.cup.and.straw", "wineglass", "cup.and.saucer", "birthday.cake", "popcorn", "carrot"]),
        ("Getting around", ["car", "bus", "tram", "bicycle", "fuelpump", "airplane", "ferry", "parkingsign", "figure.walk"]),
        ("Home & bills", ["house", "bolt", "drop", "wifi", "receipt", "wrench.and.screwdriver", "sofa", "lightbulb", "shower"]),
        ("People", ["heart", "gift", "person.2", "figure.2.and.child.holdinghands", "pawprint", "bubble.left.and.bubble.right", "figure.and.child.holdinghands", "party.popper", "envelope"]),
        ("Body & mind", ["cross.case", "pills", "dumbbell", "figure.run", "scissors", "graduationcap", "stethoscope", "brain.head.profile", "figure.yoga"]),
        ("Life", ["gamecontroller", "film", "music.note", "book", "tshirt", "beach.umbrella", "paintpalette", "camera", "guitars"]),
        ("Other", ["creditcard", "banknote", "briefcase", "square.grid.2x2", "star", "flag", "shippingbox", "wallet.pass", "puzzlepiece"]),
        ("Money in", ["chart.line.uptrend.xyaxis", "arrow.down.circle", "building.columns", "hands.clap", "sparkles", "dollarsign.circle", "banknote.fill", "briefcase.fill", "percent"]),
    ]

    static var symbols: [String] { symbolGroups.flatMap(\.symbols) }

    /// Tint and its soft background, kept as a pair so contrast never drifts.
    static let palette: [(tint: String, soft: String)] = [
        ("B5813F", "F0E6D6"), ("3F7684", "DCE7EA"), ("7A5B86", "E7DEE8"),
        ("B4694E", "F3DFD8"), ("4F7A55", "DDE8DD"), ("8F6115", "F1E4CC"),
        ("2F6A8F", "D9E6EF"), ("A34F63", "F2DDE2"), ("5B6B3F", "E2E7D6"),
        ("6B5BA6", "E1DDF0"), ("A85A2E", "F4E1D4"), ("78746A", "E4E2DB"),
        ("3F8F8A", "DCEBE9"), ("9E4F7C", "EEDCE6"), ("9C3F3F", "EDD9D9"),
        ("3F6B4A", "DCE7DE"), ("3F5B8F", "DCE2EF"), ("C97355", "F5E1D9"),
        ("8672B8", "E9E3F2"), ("8A6E5B", "EAE2DC"),
    ]

    /// What the picker shows: never archived, personal before shared, and only
    /// shared categories when a shared budget is open. `kind` splits the two
    /// sides of the ledger — pass nil to list both.
    static func visible(_ all: [SpendingCategory], scope: Scope, kind: TransactionKind? = .expense) -> [SpendingCategory] {
        all.filter { !$0.isArchived && ($0.scope == .personal || scope == .shared) && (kind == nil || $0.kind == kind) }
            .sorted { lhs, rhs in
                if lhs.scope != rhs.scope { return lhs.scope == .personal }
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func search(_ categories: [SpendingCategory], for query: String) -> [SpendingCategory] {
        let wanted = fold(query)
        guard !wanted.isEmpty else { return categories }
        return categories.filter { fold($0.name).contains(wanted) }
    }

    /// A name is free when no live category in the same scope already answers
    /// to it. Archived names stay taken — restoring must not collide.
    static func isNameAvailable(_ name: String, scope: Scope, kind: TransactionKind = .expense, in all: [SpendingCategory], excluding existing: SpendingCategory? = nil) -> Bool {
        let wanted = fold(name)
        guard !wanted.isEmpty else { return false }
        return !all.contains { candidate in
            candidate !== existing && candidate.scope == scope && candidate.kind == kind && fold(candidate.name) == wanted
        }
    }

    static func isSelectable(_ category: SpendingCategory?, scope: Scope, kind: TransactionKind = .expense) -> Bool {
        guard let category else { return false }
        return !category.isArchived && (category.scope == .personal || scope == .shared) && category.kind == kind
    }

    /// Merchant rules only ever describe spending, so an income draft matches none.
    static func ruleCategory(merchant: String, scope: Scope, kind: TransactionKind = .expense, rules: [MerchantCategoryRule]) -> SpendingCategory? {
        rules.first { $0.merchant == fold(merchant) && $0.scopeRaw == scope.rawValue && isSelectable($0.category, scope: scope, kind: kind) }?.category
    }

    // ponytail: name containment catches obvious near-duplicates; add edit distance if users need typo matching.
    static func similar(_ name: String, in categories: [SpendingCategory]) -> [SpendingCategory] {
        let wanted = fold(name)
        guard !wanted.isEmpty else { return [] }
        return categories.filter { fold($0.name).contains(wanted) || wanted.contains(fold($0.name)) }
    }

    static func nextSortIndex(in all: [SpendingCategory], scope: Scope, kind: TransactionKind = .expense) -> Int {
        (all.filter { $0.scope == scope && $0.kind == kind }.map(\.sortIndex).max() ?? 0) + 1
    }

    static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

@Generable
struct CategorySuggestion {
    var name: String
    var symbol: String
}
