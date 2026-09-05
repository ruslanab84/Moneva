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

    var body: some View {
        NavigationStack {
            Form {
                Section(subscriptions ? "Describe a monthly subscription" : "Describe one or more transactions") {
                    TextField(subscriptions ? "Netflix, 15 USD monthly, next payment September 20" : "Today, coffee 5 AZN, taxi 12 AZN", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .disabled(busy || speech.isRecording)
                    Button(speech.isRecording ? "Stop listening" : "Use microphone", systemImage: speech.isRecording ? "stop.fill" : "mic.fill") {
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
                    .disabled(busy || microphoneBusy)
                    if speech.isRecording { Text(speech.text).accessibilityLabel("Transcript: \(speech.text)") }
                    if let error = speech.error { Text(error).foregroundStyle(Palette.over) }
                    Button("Create editable drafts", systemImage: "sparkles") { draft() }
                        .disabled(busy || speech.isRecording || microphoneBusy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !drafts.isEmpty)
                    if busy { ProgressView("Processing on this iPhone…") }
                    if let reason = TransactionDrafter.unavailableReason { Text(reason).font(.footnote) }
                    Button("Enter manually") { task?.cancel(); busy = false; manual = true }
                }
                if let error { Section { Text(error).foregroundStyle(Palette.over) } }
                ForEach($drafts) { $draft in
                    Section("Draft — not saved") {
                        DraftFields(draft: $draft)
                        Button("Remove draft", role: .destructive) { drafts.removeAll { $0.id == draft.id } }
                    }
                }
                if !drafts.isEmpty {
                    Section {
                        Button("Confirm and save \(drafts.count) transactions") { save() }
                            .disabled(busy || !drafts.allSatisfy(\.canSave))
                        Button("Discard drafts and revise text", role: .destructive) { drafts = [] }
                    } footer: {
                        Text("Nothing is saved until you confirm. Currency totals are kept separate.")
                    }
                }
            }
            .navigationTitle(subscriptions ? "Smart subscription" : "Text & voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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

    private func draft() {
        busy = true
        error = nil
        let now = Date.now
        let activeScope = scope
        let input = text
        let visible = CategoryLibrary.visible(categories, scope: activeScope)
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
                        data: OnDeviceAI.context(categories: visible, now: now) + "\nRequest: " + input)
                    drafts = result.items.map { DraftResolver.resolve($0, categories: visible, rules: rules, scope: activeScope, source: source, input: input, now: now) }
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
