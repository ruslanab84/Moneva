import SwiftUI
import SwiftData

/// Scan a paper receipt, read the draft, then decide. Same contract as voice:
/// the model only fills a form, Save is the only thing that writes.
struct ReceiptScanView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Query(sort: \SpendingCategory.name) private var categories: [SpendingCategory]

    @State private var drafter = TransactionDrafter(.receipt)
    @State private var isScanning = false
    @State private var isEditing = false
    @State private var isReading = false
    @State private var scanError: String?

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }

    private var draft: TransactionDraft? {
        drafter.partial.map { DraftResolver.resolve($0, categories: categories, scope: scope) }
    }

    private var isFinal: Bool {
        if case .ready = drafter.phase { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScreenScroll(title: "Scan receipt", eyebrow: "On device") {
                if let reason = TransactionDrafter.unavailableReason {
                    EmptyHint(title: "Drafting is off", message: reason, symbol: "sparkles.slash")
                }

                camera

                if let scanError {
                    Text(scanError).font(.footnote).foregroundStyle(Palette.over).monevaCard()
                }

                if isReading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the receipt…").font(.footnote).foregroundStyle(Palette.inkMuted)
                    }
                    .monevaCard()
                }

                switch drafter.phase {
                case .idle:
                    EmptyView()
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(Palette.over).monevaCard()
                case .drafting, .ready:
                    if let draft {
                        DraftCard(draft: draft, isFinal: isFinal, currencyCode: currencyCode)
                    }
                    Text("The photo is never stored — only the text values you see, and only after you tap Save.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkFaint)
                    if isFinal, let draft {
                        DraftActions(draft: draft, edit: { isEditing = true }, save: { save(draft) })
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { drafter.prewarm(categories: categories) }
            .fullScreenCover(isPresented: $isScanning) {
                DocumentScanner { image in Task { await read(image) } }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $isEditing, onDismiss: { dismiss() }) {
                if let draft { AddTransactionView(draft: draft) }
            }
        }
    }

    private var camera: some View {
        VStack(spacing: 12) {
            Button { isScanning = true } label: {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Palette.card)
                    .frame(width: 96, height: 96)
                    .background(Palette.accent, in: .circle)
                    .shadow(color: Palette.accent.opacity(0.35), radius: 18, x: 0, y: 10)
            }
            .accessibilityLabel("Scan a receipt")

            Text("Hold steady — text is read on device")
                .font(.footnote)
                .foregroundStyle(Palette.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func read(_ image: UIImage) async {
        scanError = nil
        drafter.reset()
        isReading = true
        defer { isReading = false }
        do {
            let text = try await ReceiptText.read(image)
            await drafter.draft(from: text, categories: categories)
        } catch {
            scanError = "No text was found on that scan. Try again in better light, or add it by hand."
        }
    }

    private func save(_ draft: TransactionDraft) {
        context.insert(Transaction(
            amount: draft.amount,
            date: draft.date,
            merchant: draft.merchant,
            note: draft.note,
            kind: draft.kind,
            scope: draft.scope,
            source: .receipt,
            category: draft.category
        ))
        dismiss()
    }
}
