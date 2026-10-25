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
        ("Subscriptions", "arrow.triangle.2.circlepath", "2E7D6B", "D7EAE5"),
        ("Insurance", "lock.shield", "2B4A6F", "D8DFE8"),
        ("Taxes", "doc.text", "566573", "DFE3E7"),
        ("Charity", "hand.raised", "C25B7A", "F6DEE6"),
        ("Hobbies", "paintpalette", "B57A9E", "F2E2EC"),
        ("Fees", "creditcard", "A68A2E", "F0E8CF"),
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
        ("Bonus", "sparkles", "A68A2E", "F0E8CF"),
        ("Freelance", "laptopcomputer", "4F8FB5", "DCEAF2"),
        ("Interest", "percent", "2E7D6B", "D7EAE5"),
        ("Cashback", "arrow.uturn.backward.circle", "5E8F3F", "E0EBD6"),
        ("Other income", "square.grid.2x2", "78746A", "E4E2DB"),
    ]

    /// Built-ins added after release. Existing stores get them once; a later
    /// delete sticks because the pass never runs again.
    static let lateAdditions: Set<String> = ["Subscriptions", "Insurance", "Taxes", "Charity", "Hobbies", "Fees",
                                             "Bonus", "Freelance", "Interest", "Cashback"]

    /// Starter subcategories for built-in categories, keyed by category name.
    static let defaultSubcategories: [String: [String]] = [
        "Food": ["Breakfast", "Dining Out", "Dinner", "Groceries", "Lunch"],
        "Transport": ["Fuel", "Parking", "Public transport", "Taxi"],
        "Home": ["Furniture", "Maintenance", "Rent", "Supplies"],
        "Shopping": ["Electronics", "Household", "Online"],
        "Health": ["Doctor", "Medicine", "Pharmacy"],
        "Entertainment": ["Games", "Movies", "Music", "Events"],
        "Travel": ["Accommodation", "Flights", "Activities"],
        "Bills": ["Electricity", "Internet", "Phone", "Water"],
        "Drinks": ["Coffee", "Tea", "Alcohol"],
    ]

    /// Runs on existing stores too. A built-in category that already has any
    /// subcategory is left alone, so ones the user deleted never come back.
    static func installSubcategoriesIfNeeded(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<SpendingCategory>())) ?? []
        for category in all where category.isBuiltIn && category.kind == .expense && category.subcategories.isEmpty {
            guard let names = defaultSubcategories[category.name] else { continue }
            for (index, name) in names.enumerated() {
                context.insert(Subcategory(name: name, category: category, sortIndex: index))
            }
        }
        try? context.save()
    }

    static func installIfNeeded(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<SpendingCategory>())) ?? []
        install(defaultCategories, kind: .expense, into: all, in: context)
        // Income arrived after the first release, so this pass runs on existing stores too.
        install(defaultIncomeCategories, kind: .income, into: all, in: context)

        let key = "seed.lateAdditions.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var current = (try? context.fetch(FetchDescriptor<SpendingCategory>())) ?? []
        for (seeds, kind) in [(defaultCategories, TransactionKind.expense), (defaultIncomeCategories, .income)] {
            for item in seeds where lateAdditions.contains(item.name)
                && CategoryLibrary.isNameAvailable(item.name, scope: .personal, kind: kind, in: current) {
                let category = SpendingCategory(name: item.name, symbol: item.symbol, tintHex: item.tint, softHex: item.soft, isBuiltIn: true, kind: kind,
                                                sortIndex: CategoryLibrary.nextSortIndex(in: current, scope: .personal, kind: kind))
                context.insert(category)
                current.append(category)
            }
        }
        // Only a saved pass counts as done, so a failed save retries next launch.
        if (try? context.save()) != nil { UserDefaults.standard.set(true, forKey: key) }
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
