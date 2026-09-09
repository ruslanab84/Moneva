import Foundation
import NaturalLanguage
import SwiftData

// MARK: - CategoryExemplar

/// Logs one user category correction for a merchant, scoped to personal/shared.
/// Generalizes `MerchantCategoryRule` (exact-match) into embedding space: feeds
/// `CategoryIndex` so a merchant that *sounds like* one the user already
/// recategorized routes the same way, not just an exact-string repeat.
@Model
final class CategoryExemplar {
    var normalizedMerchant: String = ""
    var category: SpendingCategory?
    var scopeRaw: String = Scope.personal.rawValue
    var updatedAt: Date = Date.now

    var scope: Scope {
        get { Scope(rawValue: scopeRaw) ?? .personal }
        set { scopeRaw = newValue.rawValue }
    }

    init(normalizedMerchant: String, category: SpendingCategory, scope: Scope) {
        self.normalizedMerchant = normalizedMerchant
        self.category = category
        self.scopeRaw = scope.rawValue
        self.updatedAt = .now
    }

    /// One exemplar per (merchant, scope): a later correction overwrites the
    /// last one instead of piling up duplicate votes for the same merchant.
    @MainActor
    static func record(merchant: String, category: SpendingCategory, scope: Scope, in context: ModelContext) {
        let key = CategoryLibrary.fold(MerchantNameNormalizer.clean(merchant))
        guard !key.isEmpty else { return }
        let scopeRaw = scope.rawValue
        let existing = try? context.fetch(FetchDescriptor<CategoryExemplar>(
            predicate: #Predicate { $0.normalizedMerchant == key && $0.scopeRaw == scopeRaw }
        )).first
        if let existing {
            existing.category = category
            existing.updatedAt = .now
        } else {
            context.insert(CategoryExemplar(normalizedMerchant: key, category: category, scope: scope))
        }
        try? context.save()
        // invalidate() is actor-isolated; this call site stays synchronous (it's
        // reached from plain `throws` save paths, not async ones) so hand the
        // invalidation off instead of blocking on it — the next snapshot() picks
        // it up and rebuilds in the background regardless.
        Task { await CategoryIndex.shared.invalidate() }
    }
}

// MARK: - Source weighting

/// score = cosine² × sourceWeight × recencyDecay
enum SourceWeight {
    /// Generic merchant-seed guess — market knowledge, not user behavior. Set
    /// above the 0.55 confidence floor / cosine² so a near-exact seed match
    /// (cosine ~0.96+) can still classify on its own before any exemplar exists;
    /// anything cosine-weaker than that correctly falls below threshold.
    static let seed: Float = 0.6
    static let userConfirmedFresh: Float = 1.0
    /// A user correction never fully decays below this, and this stays above
    /// `seed` — otherwise an old correction could drift under a seed's static
    /// weight and the seed would silently win again, the opposite of what the
    /// user asked for.
    static let userConfirmedFloor: Float = 0.75
}

enum RecencyDecay {
    static let halfLifeDays: Double = 30

    /// `nil` reference date = seed data, timeless (decay factor 1). A user
    /// exemplar decays with a 30-day half-life, floored so it can never
    /// underweight a fresh seed match.
    static func factor(referenceDate: Date?, now: Date = .now) -> Float {
        guard let referenceDate else { return 1 }
        let days = max(0, now.timeIntervalSince(referenceDate) / 86400)
        let decayed = Float(pow(0.5, days / halfLifeDays))
        return max(decayed, SourceWeight.userConfirmedFloor / SourceWeight.userConfirmedFresh)
    }
}

// MARK: - CategoryIndex

struct CategoryIndexEntry {
    var vector: [Float]
    var categoryID: PersistentIdentifier
    /// `nil` = seed data, visible from every scope. Otherwise strict: an
    /// entry built from a `shared`-scope exemplar is never read while
    /// classifying a `personal` merchant, and vice versa.
    var scope: Scope?
    var weight: Float
    var referenceDate: Date?
}

/// Background-built, in-memory linear-scan index over merchant embeddings.
/// `snapshot` never blocks the caller: it hands back the last good snapshot
/// immediately (empty before the first warm-up) and, if stale, kicks a
/// rebuild on a detached task. A snapshot is only ever swapped in whole —
/// nothing reads a half-built array.
actor CategoryIndex {
    static let shared = CategoryIndex()

    private var entries: [CategoryIndexEntry] = []
    private var isStale = true
    private var isRebuilding = false

    /// New category / new exemplar / new seed data all invalidate — the next
    /// `snapshot` call rebuilds instead of serving the old array.
    func invalidate() {
        isStale = true
    }

    func snapshot(container: ModelContainer, embedder: TextEmbedder) -> [CategoryIndexEntry] {
        if isStale && !isRebuilding {
            isRebuilding = true
            Task.detached(priority: .utility) { [weak self] in
                let built = await Self.build(container: container, embedder: embedder)
                await self?.applyRebuilt(built)
            }
        }
        return entries
    }

    /// Awaits a full rebuild instead of firing-and-forgetting it — used by the
    /// DEBUG self-check (and an app-launch prewarm) where "eventually warm" isn't
    /// good enough, the caller needs a deterministic snapshot right now.
    func rebuildNow(container: ModelContainer, embedder: TextEmbedder) async {
        isRebuilding = true
        entries = await Self.build(container: container, embedder: embedder)
        isStale = false
        isRebuilding = false
    }

    private func applyRebuilt(_ built: [CategoryIndexEntry]) {
        entries = built
        isStale = false
        isRebuilding = false
    }

    private static func build(container: ModelContainer, embedder: TextEmbedder) async -> [CategoryIndexEntry] {
        let context = ModelContext(container)
        guard let categories = try? context.fetch(FetchDescriptor<SpendingCategory>()) else { return [] }
        var entries: [CategoryIndexEntry] = []

        let seeds = MerchantSeeds.resolved(MerchantSeeds.load(), categories: categories, strict: false)
        for (seed, category) in seeds {
            guard let vector = cachedEmbedding(for: seed.name, embedder: embedder, context: context) else { continue }
            entries.append(CategoryIndexEntry(vector: vector, categoryID: category.persistentModelID, scope: nil, weight: SourceWeight.seed, referenceDate: nil))
        }

        if let exemplars = try? context.fetch(FetchDescriptor<CategoryExemplar>()) {
            for exemplar in exemplars {
                guard let category = exemplar.category,
                      let vector = cachedEmbedding(for: exemplar.normalizedMerchant, embedder: embedder, context: context, alreadyNormalized: true)
                else { continue }
                entries.append(CategoryIndexEntry(vector: vector, categoryID: category.persistentModelID, scope: exemplar.scope, weight: SourceWeight.userConfirmedFresh, referenceDate: exemplar.updatedAt))
            }
        }
        return entries
    }

    /// `MerchantEmbedding` is the shared text->vector cache (also used by
    /// receipt/voice drafting) — reuse a stored vector before paying for a
    /// fresh on-device embedding call.
    private static func cachedEmbedding(for text: String, embedder: TextEmbedder, context: ModelContext, alreadyNormalized: Bool = false) -> [Float]? {
        let key = alreadyNormalized ? text : CategoryLibrary.fold(MerchantNameNormalizer.clean(text))
        guard !key.isEmpty else { return nil }
        if let cached = try? context.fetch(FetchDescriptor<MerchantEmbedding>(predicate: #Predicate { $0.normalizedName == key })).first {
            return cached.vector
        }
        guard let vector = embedder.embed(text, language: nil) else { return nil }
        let language = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        context.insert(MerchantEmbedding(normalizedName: key, vector: vector, language: language))
        try? context.save()
        return vector
    }
}

// MARK: - CategoryClassifier

struct ClassificationResult {
    var category: SpendingCategory
    var confidence: Float
    var margin: Float
}

enum CategoryClassifier {
    static let confidenceThreshold: Float = 0.55
    /// A confident-but-contested top-2 (e.g. two seeds pointing at different categories) must not
    /// auto-resolve just because `confidenceThreshold` cleared — margin is the second gate.
    static let marginThreshold: Float = 0.15

    static func classify(merchant: String, scope: Scope, categories: [SpendingCategory], container: ModelContainer, embedder: TextEmbedder = NLContextualTextEmbedder()) async -> ClassificationResult? {
        guard let queryVector = embedder.embed(merchant, language: nil) else { return nil }
        let entries = await CategoryIndex.shared.snapshot(container: container, embedder: embedder)
        return classify(queryVector: queryVector, scope: scope, entries: entries, categories: categories)
    }

    /// One classification per drafted item, aligned by index — each item's own `kind` picks its
    /// expense/income category set, since a voice/receipt batch can mix both.
    static func classify(_ items: [DraftedTransaction], scope: Scope, categories: [SpendingCategory], container: ModelContainer, embedder: TextEmbedder = NLContextualTextEmbedder()) async -> [ClassificationResult?] {
        var results: [ClassificationResult?] = []
        for item in items {
            let kind: TransactionKind = item.kind == .income ? .income : .expense
            let visible = CategoryLibrary.visible(categories, scope: scope, kind: kind)
            results.append(await classify(merchant: item.merchant, scope: scope, categories: visible, container: container))
        }
        return results
    }

    /// Pure scoring core, split from the async lookup above so the DEBUG
    /// self-check can drive it with fixed vectors — no model assets, no
    /// SwiftData container, fully deterministic.
    static func classify(queryVector: [Float], scope: Scope, entries: [CategoryIndexEntry], categories: [SpendingCategory]) -> ClassificationResult? {
        let query = VectorMath.normalize(queryVector)
        var bestPerCategory: [PersistentIdentifier: Float] = [:]

        for entry in entries {
            // Scope isolation is the first guard, not a post-filter — a
            // shared-scope entry never even reaches scoring for a personal query.
            guard entry.scope == nil || entry.scope == scope else { continue }
            guard entry.vector.count == query.count else { continue }
            let cosine = VectorMath.cosineSimilarity(normalized: query, entry.vector)
            let decay = RecencyDecay.factor(referenceDate: entry.referenceDate)
            let score = cosine * cosine * entry.weight * decay
            if score > (bestPerCategory[entry.categoryID] ?? -.greatestFiniteMagnitude) {
                bestPerCategory[entry.categoryID] = score
            }
        }

        let ranked = bestPerCategory.sorted { $0.value > $1.value }
        guard let top = ranked.first,
              let category = categories.first(where: { $0.persistentModelID == top.key })
        else { return nil }

        let confidence = min(top.value, 1)
        guard confidence >= confidenceThreshold else { return nil }
        let second = ranked.count > 1 ? min(ranked[1].value, 1) : 0
        return ClassificationResult(category: category, confidence: confidence, margin: confidence - second)
    }
}

#if DEBUG
@MainActor
func categoryClassifierSelfCheck() {
    let groceries = SpendingCategory(name: "Groceries", symbol: "cart", tintHex: "78746A", softHex: "E4E2DB")
    let transport = SpendingCategory(name: "Transport", symbol: "car", tintHex: "78746A", softHex: "E4E2DB")
    let categories = [groceries, transport]

    // Two orthogonal directions stand in for "grocery-shaped" vs "transport-shaped"
    // merchant text, so this runs with zero model assets and zero SwiftData I/O.
    let groceryDirection = VectorMath.normalize([1, 0, 0, 0])
    let transportDirection = VectorMath.normalize([0, 1, 0, 0])

    func entry(_ direction: [Float], category: SpendingCategory, scope: Scope?, weight: Float, referenceDate: Date?) -> CategoryIndexEntry {
        CategoryIndexEntry(vector: direction, categoryID: category.persistentModelID, scope: scope, weight: weight, referenceDate: referenceDate)
    }

    // Rule 1: a strong, on-topic match clears the 0.55 confidence floor.
    let seedOnly = [entry(groceryDirection, category: groceries, scope: nil, weight: SourceWeight.seed, referenceDate: nil)]
    let confident = CategoryClassifier.classify(queryVector: groceryDirection, scope: .personal, entries: seedOnly, categories: categories)
    assert(confident?.category === groceries, "an exact-direction seed match resolves to the seeded category")
    assert((confident?.confidence ?? 0) >= CategoryClassifier.confidenceThreshold, "cosine=1 seed match clears the confidence floor")

    // Rule 2: below-threshold matches return nil, never a low-confidence guess.
    let weakSeed = [entry(VectorMath.normalize([1, 0.05, 0, 0]), category: groceries, scope: nil, weight: SourceWeight.seed, referenceDate: nil)]
    assert(CategoryClassifier.classify(queryVector: transportDirection, scope: .personal, entries: weakSeed, categories: categories) == nil,
           "an off-topic query against a weak seed returns nil, not a low-confidence result")

    // Rule 3: a fresh user exemplar outranks a same-direction seed for a competing category.
    let contested = [
        entry(groceryDirection, category: transport, scope: nil, weight: SourceWeight.seed, referenceDate: nil),
        entry(groceryDirection, category: groceries, scope: .personal, weight: SourceWeight.userConfirmedFresh, referenceDate: .now),
    ]
    let overridden = CategoryClassifier.classify(queryVector: groceryDirection, scope: .personal, entries: contested, categories: categories)
    assert(overridden?.category === groceries, "a same-cosine user correction outranks a seed for the same merchant text")

    // Rule 4: even fully decayed, a user exemplar still outranks a same-cosine seed —
    // the whole point of flooring recency decay above the seed weight.
    let oldExemplarScore = pow(VectorMath.cosineSimilarity(normalized: groceryDirection, groceryDirection), 2)
        * SourceWeight.userConfirmedFresh * RecencyDecay.factor(referenceDate: .distantPast)
    let seedScore = pow(VectorMath.cosineSimilarity(normalized: groceryDirection, groceryDirection), 2) * SourceWeight.seed
    assert(oldExemplarScore > seedScore, "a fully-decayed user exemplar still outweighs a same-cosine seed")

    // Rule 5: scope isolation — a shared-scope exemplar must not leak into a personal classification.
    let sharedOnly = [entry(groceryDirection, category: groceries, scope: .shared, weight: SourceWeight.userConfirmedFresh, referenceDate: .now)]
    assert(CategoryClassifier.classify(queryVector: groceryDirection, scope: .personal, entries: sharedOnly, categories: categories) == nil,
           "a shared-scope exemplar is invisible to a personal-scope query")
    assert(CategoryClassifier.classify(queryVector: groceryDirection, scope: .shared, entries: sharedOnly, categories: categories)?.category === groceries,
           "the same exemplar resolves for its own scope")

    // Rule 6: margin reflects how contested the top-2 candidates are.
    let tied = [
        entry(groceryDirection, category: groceries, scope: nil, weight: SourceWeight.seed, referenceDate: nil),
        entry(VectorMath.normalize([0.99, 0.14, 0, 0]), category: transport, scope: nil, weight: SourceWeight.seed, referenceDate: nil),
    ]
    let contestedResult = CategoryClassifier.classify(queryVector: groceryDirection, scope: .personal, entries: tied, categories: categories)
    assert((contestedResult?.margin ?? 1) < 0.2, "two near-identical candidates yield a small margin")

    let clear = [entry(groceryDirection, category: groceries, scope: nil, weight: SourceWeight.seed, referenceDate: nil)]
    let clearResult = CategoryClassifier.classify(queryVector: groceryDirection, scope: .personal, entries: clear, categories: categories)
    assert((clearResult?.margin ?? 0) > (contestedResult?.margin ?? 0), "a lone strong candidate has a wider margin than a contested pair")

    // Rule 7: CategoryExemplar folds merchant text the same way the rest of the
    // app does, so an exemplar and a later lookup for "STARBUCKS #8912 SEATTLE WA"
    // key to the same normalized merchant.
    do {
        let container = try ModelContainer(for: SpendingCategory.self, CategoryExemplar.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        context.insert(groceries)
        CategoryExemplar.record(merchant: "STARBUCKS #8912 SEATTLE WA", category: groceries, scope: .personal, in: context)
        let key = CategoryLibrary.fold(MerchantNameNormalizer.clean("STARBUCKS #8912 SEATTLE WA"))
        let stored = try context.fetch(FetchDescriptor<CategoryExemplar>(predicate: #Predicate { $0.normalizedMerchant == key }))
        assert(stored.count == 1, "recording an exemplar persists exactly one row keyed by normalized merchant")

        // Recording again for the same merchant/scope overwrites rather than duplicating.
        CategoryExemplar.record(merchant: "Starbucks #1234 Austin TX", category: groceries, scope: .personal, in: context)
        let restored = try context.fetch(FetchDescriptor<CategoryExemplar>(predicate: #Predicate { $0.normalizedMerchant == key }))
        assert(restored.count == 1, "a second correction for the same merchant updates the existing exemplar, not a new row")
    } catch { assertionFailure("CategoryExemplar self-check failed: \(error)") }
}
#endif
