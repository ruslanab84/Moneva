import Foundation
import SwiftData

enum SeedData {
    /// Default categories from the PRD, with the canvas palette.
    static let defaultCategories: [(name: String, symbol: String, tint: String, soft: String)] = [
        ("Food", "fork.knife", "B5813F", "F0E6D6"),
        ("Transport", "car", "3F7684", "DCE7EA"),
        ("Home", "house", "7A5B86", "E7DEE8"),
        ("Shopping", "bag", "B4694E", "F3DFD8"),
        ("Health", "heart", "4F7A55", "DDE8DD"),
        ("Other", "square.grid.2x2", "78746A", "E4E2DB"),
    ]

    static func installIfNeeded(in context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<SpendingCategory>())) ?? 0
        guard existing == 0 else { return }
        for item in defaultCategories {
            context.insert(SpendingCategory(name: item.name, symbol: item.symbol, tintHex: item.tint, softHex: item.soft, isBuiltIn: true))
        }
        try? context.save()
    }
}
