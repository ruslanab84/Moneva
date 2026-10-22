import AppIntents
import ExtensionFoundation
import Foundation

/// Runs Shortcuts actions without launching Ledgea: no SwiftData, no self-checks, no ads —
/// just the App Group queue.
@main
nonisolated struct MonevaIntentsExtension: AppIntentsExtension {}

nonisolated struct AddApplePayPaymentIntent: AppIntent {
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
        ApplePayCapture.enqueue(payment)
        return .result(dialog: "Saved for review in Ledgea.")
    }
}
