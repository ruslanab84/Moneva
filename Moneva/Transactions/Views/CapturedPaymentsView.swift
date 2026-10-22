import SwiftUI
import SwiftData

/// Apple Pay payments the Shortcuts automation queued. Each one opens in the normal
/// confirm screen; nothing is saved until the user reviews it there.
struct CapturedPaymentsView: View {
    @AppStorage(ApplePayCapture.storageKey, store: ApplePayCapture.defaults) private var pendingRaw = ""
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @Query private var transactions: [Transaction]
    @State private var reviewing: TransactionDraft?

    private var pending: [CapturedPayment] { ApplePayCapture.decode(pendingRaw).reversed() }

    var body: some View {
        List {
            ForEach(pending) { payment in
                Button {
                    reviewing = ApplePayCapture.draft(payment, scope: Scope(rawValue: scopeRaw) ?? .personal)
                } label: {
                    LabeledContent {
                        Text(payment.amount.money(payment.currency)).foregroundStyle(Palette.ink)
                    } label: {
                        Text(payment.merchant.isEmpty ? String(localized: "Apple Pay") : payment.merchant)
                        Text(payment.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .foregroundStyle(Palette.ink)
            }
            .onDelete { offsets in
                pendingRaw = ApplePayCapture.removing(Set(offsets.map { pending[$0].id }), from: pendingRaw)
            }
            .listRowBackground(Palette.card)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .navigationTitle("Apple Pay to review")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if pending.isEmpty {
                EmptyHint(title: "Nothing to review", message: "Payments from your Apple Pay automation show up here.", symbol: "wallet.pass")
            }
        }
        .onAppear(perform: pruneSaved)
        .sheet(item: $reviewing, onDismiss: pruneSaved) { AddTransactionView(draft: $0) }
    }

    /// A saved payment carries its queue id as `draftID`; that is the only signal it was confirmed.
    private func pruneSaved() {
        let saved = Set(transactions.map(\.draftID))
        let done = Set(ApplePayCapture.decode(pendingRaw).filter { saved.contains($0.id.uuidString) }.map(\.id))
        if !done.isEmpty { pendingRaw = ApplePayCapture.removing(done, from: pendingRaw) }
    }
}
