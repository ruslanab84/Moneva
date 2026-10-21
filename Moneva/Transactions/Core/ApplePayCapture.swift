import AppIntents
import Foundation

/// One Apple Pay tap, as the Shortcuts "Transaction" automation reported it.
/// Held in a local queue until the user confirms it — never a `Transaction` by itself.
struct CapturedPayment: Codable, Identifiable, Equatable {
    var id = UUID()
    var merchant: String
    /// Kept as text: JSON numbers are not guaranteed to round-trip a `Decimal` exactly.
    var amountText: String
    var currency: String
    var date: Date

    var amount: Decimal { Decimal(string: amountText, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
}

/// The fourth draft source, next to voice, receipt and statement import. No model:
/// the merchant reaches the category through the same rule → classifier pass as manual entry.
/// The queue lives on this device only (UserDefaults) — it is never synced or sent anywhere.
enum ApplePayCapture {
    static let storageKey = "applePay.pending"
    // ponytail: capped queue, oldest dropped first; a real backlog view if anyone leaves 100 unreviewed.
    static let limit = 100

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
            currency: Money.pickerCodes.contains(code) ? code : Money.code,
            date: now)
    }

    static func appending(_ payment: CapturedPayment, to raw: String) -> String {
        encode(Array((decode(raw) + [payment]).suffix(limit)))
    }

    static func removing(_ ids: Set<UUID>, from raw: String) -> String {
        encode(decode(raw).filter { !ids.contains($0.id) })
    }

    /// Same id as the queued payment, so `DraftStore.save`'s `draftID` check keeps a second confirm from duplicating it.
    static func draft(_ payment: CapturedPayment, scope: Scope) -> TransactionDraft {
        var draft = TransactionDraft()
        draft.id = payment.id
        draft.kind = .expense
        draft.amount = payment.amount
        draft.merchant = payment.merchant
        draft.date = payment.date
        draft.currency = payment.currency
        draft.scope = scope
        draft.source = .manual
        draft.categoryConfident = false
        return draft
    }
}

struct AddApplePayPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Apple Pay payment"
    static let description = IntentDescription("Queues a payment in Ledgea for you to review. Use it in a Shortcuts Transaction automation.")

    @Parameter(title: "Merchant") var merchant: String
    @Parameter(title: "Amount") var amount: IntentCurrencyAmount

    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case invalidAmount
        var localizedStringResource: LocalizedStringResource { "The payment amount must be above zero." }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let payment = ApplePayCapture.capture(merchant: merchant, amount: amount.amount, currency: amount.currencyCode) else {
            throw Failure.invalidAmount
        }
        let defaults = UserDefaults.standard
        defaults.set(ApplePayCapture.appending(payment, to: defaults.string(forKey: ApplePayCapture.storageKey) ?? ""), forKey: ApplePayCapture.storageKey)
        return .result(dialog: "Saved for review in Ledgea.")
    }
}
