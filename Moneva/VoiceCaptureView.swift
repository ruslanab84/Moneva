import SwiftUI
import SwiftData

struct VoiceCaptureView: View {
    var subscriptions = false
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @Query private var categories: [SpendingCategory]
    @Query private var rules: [MerchantCategoryRule]
    @State private var speech = SpeechCapture()
    @State private var text = ""
    @State private var drafts: [TransactionDraft] = []
    @State private var subscriptionDraft: DetectedSubscription?
    @State private var busy = false
    @State private var microphoneBusy = false
    @State private var error: String?
    @State private var manual = false
    @State private var task: Task<Void, Never>?
    @State private var source: EntrySource = .text

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
    private var canDraft: Bool {
        !busy && !speech.isRecording && !microphoneBusy && drafts.isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MicrophoneHero(recording: speech.isRecording, busy: microphoneBusy || busy) { toggleMicrophone() }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    TextField(subscriptions ? "Netflix, 15 USD monthly, next payment September 20" : "Today, coffee 5 AZN, taxi 12 AZN", text: $text, axis: .vertical)
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(3...8)
                        .disabled(busy || speech.isRecording)
                    if speech.isRecording, !speech.text.isEmpty {
                        Text(speech.text)
                            .font(.footnote)
                            .foregroundStyle(Palette.inkMuted)
                            .accessibilityLabel("Transcript: \(speech.text)")
                    }
                    if let error = speech.error { Text(error).font(.footnote).foregroundStyle(Palette.over) }
                } header: {
                    Eyebrow(subscriptions ? "Describe a monthly subscription" : "Describe one or more transactions")
                } footer: {
                    if let reason = TransactionDrafter.unavailableReason {
                        Text(reason).font(.caption).foregroundStyle(Palette.inkMuted)
                    }
                }
                .listRowBackground(Palette.card)

                Section {
                    Button {
                        draft()
                    } label: {
                        Label("Create editable drafts", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(canDraft ? Palette.accent : Palette.inkFaint)
                    }
                    .disabled(!canDraft)
                    Button("Enter manually", systemImage: "square.and.pencil") {
                        task?.cancel()
                        busy = false
                        manual = true
                    }
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkMuted)
                    if busy {
                        HStack(spacing: 10) {
                            ProgressView().tint(Palette.accent)
                            Text("Processing on this iPhone…").font(.footnote).foregroundStyle(Palette.inkMuted)
                        }
                    }
                }
                .listRowBackground(Palette.card)

                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(Palette.over) }
                        .listRowBackground(Palette.card)
                }

                ForEach($drafts) { $draft in
                    Section {
                        AmountHero(draft: $draft)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } header: {
                        Eyebrow("Draft — not saved")
                    }
                    Section {
                        DraftFields(draft: $draft, allowKind: false, showsAmount: false)
                        Button("Remove draft", role: .destructive) { drafts.removeAll { $0.id == draft.id } }
                            .font(.subheadline)
                    }
                    .listRowBackground(Palette.card)
                }

                if !drafts.isEmpty {
                    Section {
                        Button {
                            save()
                        } label: {
                            Text("Confirm and save \(drafts.count) transactions")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .disabled(busy || !drafts.allSatisfy(\.canSave))
                        Button("Discard drafts and revise text", role: .destructive) { drafts = [] }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    } footer: {
                        Text("Nothing is saved until you confirm. Currency totals are kept separate.")
                            .font(.caption)
                            .foregroundStyle(Palette.inkMuted)
                    }
                    .listRowBackground(Palette.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .tint(Palette.accent)
            .navigationTitle(subscriptions ? "Smart subscription" : "Text & voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.inkMuted)
                }
            }
            .sheet(isPresented: $manual) {
                if subscriptions { SubscriptionEditorView(scope: scope) } else { AddTransactionView() }
            }
            .sheet(item: $subscriptionDraft) { draft in
                SubscriptionEditorView(scope: scope, draft: draft, onSaved: { dismiss() })
            }
            .onDisappear {
                task?.cancel()
                Task { await speech.stop() }
            }
        }
    }

    private func toggleMicrophone() {
        microphoneBusy = true
        task = Task {
            if speech.isRecording {
                await speech.stop()
                text = speech.text
                source = .voice
            } else {
                await speech.start()
            }
            microphoneBusy = false
        }
    }

    private func draft() {
        busy = true
        error = nil
        let now = Date.now
        let activeScope = scope
        let input = text
        let visible = CategoryLibrary.visible(categories, scope: activeScope)
        // Drafting covers both sides of the ledger; subscriptions are spending only.
        let library = CategoryLibrary.visible(categories, scope: activeScope, kind: nil)
        task = Task {
            defer { busy = false }
            do {
                if subscriptions {
                    let result = try await OnDeviceAI.generate(DraftedMonthlySubscription.self,
                        instructions: "Extract a monthly subscription draft. Use only stated values. If the year is omitted, use the next occurrence of the stated month and day. Flag non-monthly frequencies and ambiguities for review.",
                        data: OnDeviceAI.context(categories: visible, now: now) + "\nRequest: " + input)
                    subscriptionDraft = SubscriptionResolver.resolveInput(result, categories: visible, scope: activeScope, input: input, now: now)
                } else {
                    let result = try await OnDeviceAI.generate(DraftedTransactions.self,
                        instructions: "Extract every expense or income as a separate draft. Resolve relative language into signed day offsets; explicit dates into year/month/day. If a transaction date is not mentioned, use today (offset 0). Never assume a currency; ask if absent. Flag ambiguous amounts and dates. Suggest an existing category before a new category.",
                        data: OnDeviceAI.context(categories: library, now: now) + "\nRequest: " + input)
                    drafts = result.items.map { DraftResolver.resolve($0, categories: library, rules: rules, scope: activeScope, source: source, input: input, now: now) }
                    if drafts.isEmpty { error = "No transactions found. Add amounts and currencies, or enter manually." }
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try DraftStore.save(drafts, in: context); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

/// The microphone is the point of this screen, so it gets the card and the
/// tap target instead of an anonymous form row.
struct MicrophoneHero: View {
    let recording: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(recording ? Palette.accent : Palette.accentSoft)
                        .frame(width: 84, height: 84)
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(recording ? Palette.card : Palette.accent)
                }
                VStack(spacing: 2) {
                    Text(recording ? "Listening…" : "Tap to speak")
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                    Text(recording ? "Tap again to stop" : "Or type it below")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .monevaCard()
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .accessibilityLabel(recording ? "Stop listening" : "Use microphone")
    }
}
