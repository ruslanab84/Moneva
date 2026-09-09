import Foundation

/// One row of `Resources/merchant-seeds.json` — a merchant name as it appears
/// on a receipt/statement, its expense category, and the ISO country codes it's seen in.
struct MerchantSeed: Codable {
    var name: String
    var category: String
    var markets: [String]
}

enum MerchantSeeds {
    static func load(bundle: Bundle = .main) -> [MerchantSeed] {
        guard let url = bundle.url(forResource: "merchant-seeds", withExtension: "json", subdirectory: "Resources")
                ?? bundle.url(forResource: "merchant-seeds", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let seeds = try? JSONDecoder().decode([MerchantSeed].self, from: data) else {
            assertionFailure("merchant-seeds.json is missing or malformed")
            return []
        }
        return seeds
    }

    /// Categories are user data, not a fixed enum, so each seed's category name is
    /// resolved against whatever expense categories actually exist (merchant rules
    /// only ever describe spending — see CategoryLibrary.ruleCategory).
    ///
    /// `strict` only makes sense against the shipped default catalogue (the
    /// self-check): a live user's categories are user-editable and can drop or
    /// rename any of them, so runtime callers must skip an unresolved seed
    /// instead of asserting.
    static func resolved(_ seeds: [MerchantSeed], categories: [SpendingCategory], strict: Bool = true) -> [(seed: MerchantSeed, category: SpendingCategory)] {
        seeds.compactMap { seed in
            guard let category = categories.first(where: { $0.kind == .expense && CategoryLibrary.fold($0.name) == CategoryLibrary.fold(seed.category) }) else {
                if strict {
                    assertionFailure("merchant-seeds.json references unknown category \"\(seed.category)\" for \(seed.name)")
                }
                return nil
            }
            return (seed, category)
        }
    }
}
