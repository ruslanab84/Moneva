import Foundation

/// Rates the user typed in Settings. They only convert a total at display time —
/// a stored amount and its currency never change. A pair is keyed by both codes,
/// so switching the display currency simply leaves the old rates unused.
struct ExchangeRates: Equatable {
    static let storageKey = "exchangeRates"
    static let empty = ExchangeRates(raw: "")
    static var stored: ExchangeRates { ExchangeRates(raw: UserDefaults.standard.string(forKey: storageKey) ?? "") }

    private(set) var rates: [String: Decimal] = [:]

    /// "USD>AZN=1.7;EUR>AZN=1.93" — fits in `@AppStorage`, so views redraw on edit.
    init(raw: String) {
        for entry in raw.split(separator: ";") {
            let parts = entry.split(separator: "=")
            guard parts.count == 2, let rate = Money.parse(String(parts[1])), rate > 0 else { continue }
            rates[String(parts[0])] = rate
        }
    }

    var raw: String {
        rates.keys.sorted().map { "\($0)=\(NSDecimalNumber(decimal: rates[$0]!).stringValue)" }.joined(separator: ";")
    }

    func rate(from: String, to: String) -> Decimal? { from == to ? 1 : rates["\(from)>\(to)"] }

    /// nil when there is no rate: such an amount stays out of the total, as before.
    func convert(_ amount: Decimal, from: String, to: String) -> Decimal? {
        guard let rate = rate(from: from, to: to) else { return nil }
        return from == to ? amount : Budgeting.rounded(amount * rate, currency: to)
    }

    mutating func set(_ rate: Decimal?, from: String, to: String) {
        guard from != to else { return }
        rates["\(from)>\(to)"] = rate.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Codes among `currencies` that have no rate to `target` and so are left out.
    func missing(_ currencies: some Sequence<String>, to target: String) -> [String] {
        Set(currencies).filter { rate(from: $0, to: target) == nil }.sorted()
    }
}
