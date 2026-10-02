import SwiftUI
import SwiftData
import FoundationModels

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
    @State private var drafter: TransactionDrafter?
    @State private var refinement = ""
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
                    }
                    Section {
                        DraftFields(draft: $draft, allowKind: false, showsAmount: false)
                        if drafts.count > 1 {
                            Button("Save this transaction") { saveOne(draft) }
                                .font(.subheadline.weight(.semibold))
                                .disabled(busy || !draft.canSave)
                        }
                        Button("Remove draft", role: .destructive) {
                            drafts.removeAll { $0.id == draft.id }
                            // Last one out also clears the source text — otherwise the form still
                            // shows the same input sitting there ready to redraft, which reads as
                            // "removing did nothing."
                            if drafts.isEmpty { text = ""; refinement = "" }
                        }
                            .font(.subheadline)
                    }
                    .listRowBackground(Palette.card)
                }

                if !drafts.isEmpty {
                    Section {
                        TextField("e.g. that was for two people, wrong currency", text: $refinement, axis: .vertical)
                            .font(.subheadline)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1...4)
                            .disabled(busy)
                        Button("Refine", systemImage: "arrow.triangle.2.circlepath") { refine() }
                            .font(.subheadline.weight(.semibold))
                            .disabled(busy || refinement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Eyebrow("Correct the draft above")
                    }
                    .listRowBackground(Palette.card)
                }

                if drafts.count == 1 {
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
                        Button("Discard drafts and revise text", role: .destructive) { discard() }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    } footer: {
                        Text("Nothing is saved until you confirm. Currency totals are kept separate.")
                            .font(.caption)
                            .foregroundStyle(Palette.inkMuted)
                    }
                    .listRowBackground(Palette.card)
                } else if !drafts.isEmpty {
                    Section {
                        Button("Discard remaining drafts", role: .destructive) { discard() }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    } footer: {
                        Text("Each draft saves separately. Nothing is saved until you tap Save on it.")
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
            .onAppear {
                guard !subscriptions, drafter == nil else { return }
                let library = CategoryLibrary.visible(categories, scope: scope, kind: nil)
                let session = TransactionDrafter(categories: library)
                drafter = session
                session.prewarm()
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
                    // Reuse the session warmed on sheet appear when its category set still applies.
                    let session = drafter ?? TransactionDrafter(categories: library)
                    drafter = session
                    let items = try await session.draftTransactions(from: input, now: now)
                    let classifications = await CategoryClassifier.classify(items, scope: activeScope, categories: library, container: context.container)
                    drafts = DraftResolver.resolve(items, categories: library, rules: rules, scope: activeScope, source: source, input: input, now: now, classifications: classifications)
                    if drafts.isEmpty {
                        error = "No transactions found. Add amounts and currencies, or enter manually."
                    } else if drafts.allSatisfy({ $0.clarification.isEmpty && Money.valid($0.amount, currency: $0.currency)
                        && CategoryLibrary.isSelectable($0.category, scope: $0.scope, kind: $0.kind) }) {
                        // Clean extraction, nothing the model flagged — save straight through instead
                        // of making the user re-confirm what it already got right. Anything ambiguous
                        // (missing amount/category, a clarification question) still falls through to
                        // the editable review section below, since there's nothing valid to save yet.
                        for index in drafts.indices { drafts[index].reviewed = true }
                        do { try DraftStore.save(drafts, in: context); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } catch is CancellationError {
            } catch let failure as LanguageModelSession.GenerationError {
                switch failure {
                case .guardrailViolation, .assetsUnavailable, .exceededContextWindowSize:
                    drafts = [DraftResolver.ruleFallback(input: input, rules: rules, scope: activeScope, source: source)]
                    error = "On-device drafting could not finish. A draft was started from known merchant rules — review it below."
                default:
                    self.error = failure.localizedDescription
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Regenerates over the same live session so the model sees its own prior draft — the sheet's
    /// "Refine" field, distinct from `draft()` which always starts a new topic/session.
    private func refine() {
        guard let drafter, !refinement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        error = nil
        let now = Date.now
        let activeScope = scope
        let correction = refinement
        let groundingText = text + "\n" + correction
        let library = CategoryLibrary.visible(categories, scope: activeScope, kind: nil)
        task = Task {
            defer { busy = false }
            do {
                let items = try await drafter.refine(correction, now: now)
                let classifications = await CategoryClassifier.classify(items, scope: activeScope, categories: library, container: context.container)
                drafts = DraftResolver.resolve(items, categories: library, rules: rules, scope: activeScope, source: source, input: groundingText, now: now, classifications: classifications)
                refinement = ""
            } catch is CancellationError {
            } catch let failure as LanguageModelSession.GenerationError {
                switch failure {
                case .guardrailViolation, .assetsUnavailable, .exceededContextWindowSize:
                    error = "On-device drafting could not finish. The draft above is kept as-is — edit it manually."
                default:
                    self.error = failure.localizedDescription
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func discard() {
        drafts = []
        refinement = ""
        let library = CategoryLibrary.visible(categories, scope: scope, kind: nil)
        let session = TransactionDrafter(categories: library)
        drafter = session
        session.prewarm()
    }

    private func save() {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try DraftStore.save(drafts, in: context); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    /// Batch confirm-UI: each draft saves on its own, so one bad draft never blocks the rest.
    private func saveOne(_ draft: TransactionDraft) {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try DraftStore.save([draft], in: context); drafts.removeAll { $0.id == draft.id } }
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
