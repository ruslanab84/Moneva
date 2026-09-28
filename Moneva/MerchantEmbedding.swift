import Foundation
import NaturalLanguage
import Accelerate
import SwiftData

// MARK: - Vector math

/// Accelerate-backed vector ops. Every vector this app compares is L2-normalized
/// before it's stored, so `cosineSimilarity(normalized:_:)` is a bare dot product —
/// no magnitude division at compare time.
enum VectorMath {
    static func normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let magnitude = sqrt(sumOfSquares)
        guard magnitude > 0 else { return vector }
        var divisor = magnitude
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Mean of per-subword vectors into one merchant-level vector.
    /// ponytail: plain Swift, not vDSP — pooling reads and writes the same
    /// accumulator, and handing vDSP the same array as both source and
    /// destination pointer in one call risks a Swift exclusivity trap; a few
    /// subwords per merchant name isn't worth the risk for the perf.
    static func meanPool(_ vectors: [[Float]]) -> [Float] {
        precondition(!vectors.isEmpty, "meanPool needs at least one vector")
        let dimension = vectors[0].count
        var sum = [Float](repeating: 0, count: dimension)
        for vector in vectors {
            precondition(vector.count == dimension, "all pooled vectors must share a dimension")
            for i in 0..<dimension { sum[i] += vector[i] }
        }
        let divisor = Float(vectors.count)
        return sum.map { $0 / divisor }
    }

    /// Cosine similarity for two vectors that are ALREADY L2-normalized.
    static func cosineSimilarity(normalized a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "vectors must share a dimension")
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }
}

// MARK: - Text embedding

protocol TextEmbedder {
    /// One pooled, L2-normalized vector for `text`. `nil` when the language/script
    /// has no on-device contextual embedding model, or its assets aren't
    /// downloaded yet — never a crash.
    func embed(_ text: String, language: NLLanguage?) -> [Float]?
}

/// Wraps `NLContextualEmbedding`. Models are loaded lazily, one per language, on
/// first use; `prewarm` kicks off an asset download ahead of that without
/// blocking `embed`.
///
/// `nonisolated` opts this out of the module's default MainActor isolation —
/// every call site runs it off the main actor (`CategoryIndex`'s background
/// rebuild, the async `CategoryClassifier.classify`), and a default-argument
/// `NLContextualTextEmbedder()` needs a nonisolated init to be usable there.
nonisolated final class NLContextualTextEmbedder: TextEmbedder {
    private var models: [NLLanguage: NLContextualEmbedding] = [:]

    func prewarm(language: NLLanguage) async {
        guard let model = model(for: language), !model.hasAvailableAssets else { return }
        await withCheckedContinuation { continuation in
            model.requestAssets { _, _ in continuation.resume() }
        }
    }

    func embed(_ text: String, language: NLLanguage? = nil) -> [Float]? {
        guard let resolvedLanguage = language ?? NLLanguageRecognizer.dominantLanguage(for: text),
              let model = model(for: resolvedLanguage), model.hasAvailableAssets,
              let result = try? model.embeddingResult(for: text, language: resolvedLanguage)
        else { return nil }
        let subwordVectors = tokenVectors(result)
        guard !subwordVectors.isEmpty else { return nil }
        return VectorMath.normalize(VectorMath.meanPool(subwordVectors))
    }

    private func model(for language: NLLanguage) -> NLContextualEmbedding? {
        if let cached = models[language] { return cached }
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        models[language] = model
        return model
    }

    /// `NLContextualEmbedding` returns one vector per subword, not one per string —
    /// walk all of them so `embed` can pool into a single merchant-level vector.
    private func tokenVectors(_ result: NLContextualEmbeddingResult) -> [[Float]] {
        var vectors: [[Float]] = []
        result.enumerateTokenVectors(in: result.string.startIndex..<result.string.endIndex) { vector, _ in
            vectors.append(vector.map(Float.init))
            return true
        }
        return vectors
    }
}

// MARK: - Merchant name cleanup

/// Strips the noise statement/receipt formatting adds around a merchant's real
/// name, so near-duplicate merchants (same business, different card mask or
/// store branch) fold to the same normalized key.
enum MerchantNameNormalizer {
    // ponytail: regex heuristics for the three noisiest receipt shapes. Extend
    // this list if a new noise pattern shows up in real statement data.
    private static let noisePatterns: [NSRegularExpression] = [
        #"\*[A-Za-z0-9]{3,}"#,           // card mask: *1234, *A1B2C3
        #"#\d+"#,                         // terminal/order id: #8912
        #"\s+[\p{L}.'-]+\s+[A-Z]{2}$"#,   // trailing city + 2-letter state/country: LONDON GB, AUSTIN TX
    ].map { try! NSRegularExpression(pattern: $0) }

    static func clean(_ raw: String) -> String {
        var text = raw
        for pattern in noisePatterns {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        return text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Persistence

@Model
final class MerchantEmbedding {
    @Attribute(.unique) var normalizedName: String = ""
    var embeddingData: Data = Data()
    var dimension: Int = 0
    var languageCode: String = ""
    var updatedAt: Date = Date.now

    init(normalizedName: String, vector: [Float], language: NLLanguage) {
        self.normalizedName = normalizedName
        self.embeddingData = MerchantEmbedding.encode(vector)
        self.dimension = vector.count
        self.languageCode = language.rawValue
        self.updatedAt = .now
    }

    var vector: [Float] { MerchantEmbedding.decode(embeddingData) }

    static func encode(_ vector: [Float]) -> Data {
        vector.map(Float16.init).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Copies bytes out rather than binding `Data`'s storage in place — `Data`
    /// makes no alignment guarantee, and `Float16` needs 2-byte alignment.
    static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float16>.size
        var float16s = [Float16](repeating: 0, count: count)
        _ = float16s.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return float16s.map(Float.init)
    }
}

#if DEBUG
@MainActor
func merchantEmbeddingSelfCheck() {
    // Exact-equality asserts are the wrong tool here: a normalized vector's
    // self-cosine is only "==1" in exact math. Float error, and the Float16
    // storage round-trip below, put it a hair off — tolerance, not ==.
    let a = VectorMath.normalize([3, 4, 0, 0])
    let b = VectorMath.normalize([0, 0, 5, 12])
    let selfCosine = VectorMath.cosineSimilarity(normalized: a, a)
    assert(abs(selfCosine - 1.0) < 1e-5, "a normalized vector's cosine with itself is ~1, got \(selfCosine)")
    let orthogonal = VectorMath.cosineSimilarity(normalized: a, b)
    assert(abs(orthogonal) < 1e-5, "vectors sharing no non-zero axis are ~orthogonal, got \(orthogonal)")

    // meanPool + normalize: the two steps embed(_:language:) runs over subword vectors.
    let pooled = VectorMath.normalize(VectorMath.meanPool([[1, 0, 0], [0, 1, 0]]))
    assert(abs(VectorMath.cosineSimilarity(normalized: pooled, pooled) - 1.0) < 1e-5, "pooling then normalizing still yields a unit vector")

    // Float16 round-trip: ~3 decimal digits of precision, so the tolerance has
    // to be Float16-sized. This is the #1 way this self-check trips in practice.
    let original = VectorMath.normalize((0..<32).map { Float(($0 % 7) - 3) })
    let roundTripped = MerchantEmbedding.decode(MerchantEmbedding.encode(original))
    assert(roundTripped.count == original.count, "Float16 round-trip preserves dimension")
    let roundTripCosine = VectorMath.cosineSimilarity(normalized: original, VectorMath.normalize(roundTripped))
    assert(abs(roundTripCosine - 1.0) < 1e-2, "Float16 compression keeps direction within ~1%, got \(roundTripCosine)")

    // An unrecognized language/script returns nil instead of crashing — no
    // downloaded assets required, so this runs the same on every machine.
    let embedder = NLContextualTextEmbedder()
    assert(embedder.embed("test merchant", language: NLLanguage("xx-Unsupported")) == nil, "an unsupported language gracefully returns nil")

    // Merchant name cleanup across 4 receipt markets: card mask, terminal id,
    // and city+region tail, alone and combined.
    let cases: [(raw: String, expected: String)] = [
        ("WALMART #4521 AUSTIN TX", "WALMART"),
        ("TESCO EXPRESS LONDON GB", "TESCO EXPRESS"),
        ("REWE SAGT DANKE BERLIN DE", "REWE SAGT DANKE"),
        ("WOOLWORTHS *1234 SYDNEY AU", "WOOLWORTHS"),
    ]
    for testCase in cases {
        let cleaned = MerchantNameNormalizer.clean(testCase.raw)
        assert(cleaned == testCase.expected, "\(testCase.raw) -> \"\(cleaned)\", expected \"\(testCase.expected)\"")
    }

    // MerchantEmbedding persists under a unique, folded normalizedName key and
    // decodes back a vector that still points the same direction.
    do {
        let container = try ModelContainer(for: MerchantEmbedding.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let key = CategoryLibrary.fold(MerchantNameNormalizer.clean("STARBUCKS #8912 SEATTLE WA"))
        context.insert(MerchantEmbedding(normalizedName: key, vector: original, language: .english))
        try context.save()
        let fetched = try context.fetch(FetchDescriptor<MerchantEmbedding>(predicate: #Predicate { $0.normalizedName == key }))
        assert(fetched.count == 1, "normalizedName round-trips through the store as the dedup key")
        let storedCosine = VectorMath.cosineSimilarity(normalized: original, VectorMath.normalize(fetched[0].vector))
        assert(abs(storedCosine - 1.0) < 1e-2, "the vector read back from SwiftData still points the same direction")
    } catch { assertionFailure("MerchantEmbedding self-check failed: \(error)") }
}
#endif
