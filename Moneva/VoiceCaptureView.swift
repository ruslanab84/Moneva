import SwiftUI
import SwiftData

/// Speak a transaction, read the draft, then decide. Nothing reaches the store
/// until Save — the model only ever fills a form.
struct VoiceCaptureView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Query(sort: \SpendingCategory.name) private var categories: [SpendingCategory]

    @State private var speech = SpeechCapture()
    @State private var drafter = TransactionDrafter()
    @State private var isEditing = false

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }

    /// Rebuilt from the model's latest snapshot, so the card fills in as the
    /// draft streams rather than appearing whole at the end.
    private var draft: TransactionDraft? {
        drafter.partial.map { DraftResolver.resolve($0, categories: categories, scope: scope) }
    }

    private var isFinal: Bool {
        if case .ready = drafter.phase { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScreenScroll(title: "Voice expense", eyebrow: "On device") {
                if let reason = TransactionDrafter.unavailableReason {
                    EmptyHint(title: "Drafting is off", message: reason, symbol: "sparkles.slash")
                }

                microphone

                if !speech.text.isEmpty {
                    Text("“\(speech.text)”")
                        .font(.body)
                        .foregroundStyle(Palette.ink)
                        .monevaCard()
                }

                if let message = speech.error {
                    Text(message).font(.footnote).foregroundStyle(Palette.over)
                }

                switch drafter.phase {
                case .idle:
                    EmptyView()
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(Palette.over).monevaCard()
                case .drafting, .ready:
                    if let draft {
                        draftCard(draft)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading that…").font(.footnote).foregroundStyle(Palette.inkMuted)
                        }
                        .monevaCard()
                    }
                    Text("Moneva only drafts. Nothing is written to your data until you tap Save.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkFaint)
                    if isFinal, let draft { actions(for: draft) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task { await speech.stop(); dismiss() }
                    }
                }
            }
            .onAppear { drafter.prewarm(categories: categories) }
            .sheet(isPresented: $isEditing, onDismiss: { dismiss() }) {
                if let draft { AddTransactionView(draft: draft) }
            }
        }
    }

    private var microphone: some View {
        VStack(spacing: 12) {
            Button {
                Task { await toggleRecording() }
            } label: {
                Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Palette.card)
                    .frame(width: 96, height: 96)
                    .background(speech.isRecording ? Palette.over : Palette.accent, in: .circle)
                    .shadow(color: Palette.accent.opacity(0.35), radius: 18, x: 0, y: 10)
            }
            .accessibilityLabel(speech.isRecording ? "Stop listening" : "Start listening")

            Text(speech.isRecording ? "Listening — tap to stop" : "Speech stays on this iPhone")
                .font(.footnote)
                .foregroundStyle(Palette.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func draftCard(_ draft: TransactionDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Eyebrow(isFinal ? "Draft — on-device model" : "Drafting on device")
                if !isFinal { ProgressView().controlSize(.mini) }
                Spacer()
                Text("Not saved yet")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.warning)
            }

            HStack(spacing: 12) {
                CategoryBadge(category: draft.category)
                Text((draft.kind == .income ? "+" : "−") + draft.amount.money(currencyCode))
                    .font(.money(.largeTitle))
                    .foregroundStyle(Palette.ink)
            }

            VStack(spacing: 0) {
                field("Merchant", draft.merchant.isEmpty ? "—" : draft.merchant)
                field("Category", draft.category?.name ?? (draft.kind == .income ? "Income" : "—"))
                field("Date", draft.date.formatted(date: .abbreviated, time: .omitted))
                field("Scope", draft.scope.title)
                if !draft.note.isEmpty { field("Note", draft.note) }
            }
        }
        .monevaCard()
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.footnote).foregroundStyle(Palette.inkMuted)
            Spacer(minLength: 12)
            Text(value).font(.subheadline).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func actions(for draft: TransactionDraft) -> some View {
        HStack(spacing: 12) {
            Button("Edit") { isEditing = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Palette.card, in: .rect(cornerRadius: 16))

            Button("Save transaction") { save(draft) }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.card)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Palette.accent, in: .rect(cornerRadius: 16))
                .disabled(draft.amount <= 0)
        }
    }

    private func toggleRecording() async {
        if speech.isRecording {
            await speech.stop()
            await drafter.draft(from: speech.text, categories: categories)
        } else {
            drafter.reset()
            await speech.start()
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
            source: .voice,
            category: draft.category
        ))
        dismiss()
    }
}
