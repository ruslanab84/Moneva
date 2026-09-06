import Foundation
import SwiftData

enum SeedData {
    /// Default categories from the PRD, with the canvas palette.
    static let defaultCategories: [(name: String, symbol: String, tint: String, soft: String)] = [
        ("Food", "fork.knife", "B5813F", "F0E6D6"),
        ("Transport", "car", "3F7684", "DCE7EA"),
        ("Home", "house", "7A5B86", "E7DEE8"),
        ("Shopping", "bag", "B4694E", "F3DFD8"),
        ("Health", "cross.case", "4F7A55", "DDE8DD"),
        ("Education", "graduationcap", "2F6A8F", "D9E6EF"),
        ("Entertainment", "gamecontroller", "6B5BA6", "E1DDF0"),
        ("Travel", "airplane", "3F7684", "DCE7EA"),
        ("Beauty", "scissors", "A34F63", "F2DDE2"),
        ("Pets", "pawprint", "8F6115", "F1E4CC"),
        ("Baby", "figure.2.and.child.holdinghands", "A85A2E", "F4E1D4"),
        ("Sports", "dumbbell", "5B6B3F", "E2E7D6"),
        ("Gifts", "gift", "A34F63", "F2DDE2"),
        ("Bills", "receipt", "78746A", "E4E2DB"),
        ("Social Life", "bubble.left.and.bubble.right", "6B5BA6", "E1DDF0"),
        ("Clothing", "tshirt", "B4694E", "F3DFD8"),
        ("Drinks", "cup.and.saucer", "B5813F", "F0E6D6"),
        ("Other", "square.grid.2x2", "78746A", "E4E2DB"),
    ]

    /// Where money comes from. Kept apart from spending so the two pickers
    /// never show each other's categories.
    static let defaultIncomeCategories: [(name: String, symbol: String, tint: String, soft: String)] = [
        ("Salary", "briefcase", "4F7A55", "DDE8DD"),
        ("Deposit", "banknote", "3F7684", "DCE7EA"),
        ("Rent", "house", "7A5B86", "E7DEE8"),
        ("Investment", "chart.line.uptrend.xyaxis", "2F6A8F", "D9E6EF"),
        ("Business", "building.columns", "8F6115", "F1E4CC"),
        ("Gift", "gift", "A34F63", "F2DDE2"),
        ("Refund", "arrow.down.circle", "5B6B3F", "E2E7D6"),
        ("Other income", "square.grid.2x2", "78746A", "E4E2DB"),
    ]

    static func installIfNeeded(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<SpendingCategory>())) ?? []
        install(defaultCategories, kind: .expense, into: all, in: context)
        // Income arrived after the first release, so this pass runs on existing stores too.
        install(defaultIncomeCategories, kind: .income, into: all, in: context)
    }

    private static func install(_ seeds: [(name: String, symbol: String, tint: String, soft: String)],
                                kind: TransactionKind, into existing: [SpendingCategory], in context: ModelContext) {
        guard !existing.contains(where: { $0.kind == kind }) else { return }
        for (index, item) in seeds.enumerated() {
            context.insert(SpendingCategory(name: item.name, symbol: item.symbol, tintHex: item.tint, softHex: item.soft, isBuiltIn: true, kind: kind, sortIndex: index))
        }
        try? context.save()
    }
}
