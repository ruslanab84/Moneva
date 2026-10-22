import Foundation

/// App side of the Apple Pay queue (`MonevaShared/ApplePayQueue.swift`); the intent itself
/// lives in the MonevaIntents extension so an Apple Pay tap never has to launch the app.
extension ApplePayCapture {
    /// Same id as the queued payment, so `DraftStore.save`'s `draftID` check keeps a second confirm from duplicating it.
    static func draft(_ payment: CapturedPayment, scope: Scope) -> TransactionDraft {
        var draft = TransactionDraft()
        draft.id = payment.id
        draft.kind = .expense
        draft.amount = payment.amount
        draft.merchant = payment.merchant
        draft.date = payment.date
        // The extension cannot read the display currency; an empty code means "use it".
        draft.currency = payment.currency.isEmpty ? Money.code : payment.currency
        draft.scope = scope
        draft.source = .manual
        draft.categoryConfident = false
        return draft
    }

    /// Builds before the extension queued into the app's own defaults; moved over once.
    static func migrateLegacyQueue(from legacy: UserDefaults = .standard) {
        guard let raw = legacy.string(forKey: storageKey) else { return }
        for payment in decode(raw) { enqueue(payment) }
        legacy.removeObject(forKey: storageKey)
    }
}
