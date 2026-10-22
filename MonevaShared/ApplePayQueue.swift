import Foundation

/// One Apple Pay tap, as the Shortcuts "Transaction" automation reported it.
/// Held in a local queue until the user confirms it — never a `Transaction` by itself.
nonisolated struct CapturedPayment: Codable, Identifiable, Equatable {
    var id = UUID()
    var merchant: String
    /// Kept as text: JSON numbers are not guaranteed to round-trip a `Decimal` exactly.
    var amountText: String
    /// Empty when the shortcut sent no usable code; the app reads that as its display currency.
    var currency: String
    var date: Date

    var amount: Decimal { Decimal(string: amountText, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
}

/// The fourth draft source, next to voice, receipt and statement import. No model:
/// the merchant reaches the category through the same rule → classifier pass as manual entry.
/// Compiled into the app and the App Intents extension: the extension appends without
/// launching the app, the app drains. The queue lives in the App Group defaults on this
/// device only — it is never synced or sent anywhere.
nonisolated enum ApplePayCapture {
    static let storageKey = "applePay.pending"
    // ponytail: capped queue, oldest dropped first; a real backlog view if anyone leaves 100 unreviewed.
    static let limit = 100

    static var defaults: UserDefaults { BudgetSnapshot.defaults }

    static func decode(_ raw: String) -> [CapturedPayment] {
        (try? JSONDecoder().decode([CapturedPayment].self, from: Data(raw.utf8))) ?? []
    }

    static func encode(_ payments: [CapturedPayment]) -> String {
        (try? JSONEncoder().encode(payments)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Shortcut input is untrusted — any shortcut can call the intent with anything.
    static func capture(merchant: String, amount: Decimal, currency: String, now: Date = .now) -> CapturedPayment? {
        guard !amount.isNaN, amount > 0, amount < Decimal(1_000_000_000_000) else { return nil }
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return CapturedPayment(
            merchant: String(merchant.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)),
            amountText: NSDecimalNumber(decimal: amount).stringValue,
            currency: Locale.commonISOCurrencyCodes.contains(code) ? code : "",
            date: now)
    }

    static func appending(_ payment: CapturedPayment, to raw: String) -> String {
        encode(Array((decode(raw) + [payment]).suffix(limit)))
    }

    static func removing(_ ids: Set<UUID>, from raw: String) -> String {
        encode(decode(raw).filter { !ids.contains($0.id) })
    }

    static func enqueue(_ payment: CapturedPayment) {
        defaults.set(appending(payment, to: defaults.string(forKey: storageKey) ?? ""), forKey: storageKey)
    }
}
