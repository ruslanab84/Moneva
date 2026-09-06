import SwiftUI
import SwiftData

struct AddTransactionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @State private var draft: TransactionDraft
    @State private var error: String?
    @State private var saved = false
    private let prefilled: Bool

    init(draft: TransactionDraft? = nil) {
        _draft = State(initialValue: draft ?? TransactionDraft(reviewed: true))
        prefilled = draft != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountHero(draft: $draft)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    DraftFields(draft: $draft, requiresReview: prefilled, allowKind: false, showsAmount: false)
                }
                .listRowBackground(Palette.card)
                if let error {
                    Section { Text(error).foregroundStyle(Palette.over) }
                        .listRowBackground(Palette.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .tint(Palette.accent)
            .navigationTitle("New transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.inkMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try DraftStore.save([draft], in: context); saved = true; dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(saved || !draft.canSave)
                }
            }
            .onAppear { if !prefilled { draft.scope = Scope(rawValue: scopeRaw) ?? .personal } }
        }
    }
}

struct DraftFields: View {
    @Binding var draft: TransactionDraft
    var requiresReview = true
    var allowKind = true
    var showsAmount = true
    @Query private var rules: [MerchantCategoryRule]
    @Query private var categories: [SpendingCategory]
    @State private var picking = false
    @State private var suggesting = false
    @State private var suggestionError: String?

    var body: some View {
        Group {
            if allowKind {
                Picker("Kind", selection: $draft.kind) {
                    ForEach(TransactionKind.allCases) { Text($0.title).tag($0) }
                }
            }
            if showsAmount {
                AmountField(title: "Amount", value: $draft.amount, currencyCode: draft.currency)
                Picker("Currency", selection: $draft.currency) {
                    ForEach(Money.pickerCodes, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Merchant or source", text: $draft.merchant)
            DatePicker("Date", selection: $draft.date, displayedComponents: .date)
            Picker("Scope", selection: $draft.scope) {
                ForEach(Scope.allCases) { Text($0.title).tag($0) }
            }
            categoryFields
            TextField("Note", text: $draft.note, axis: .vertical)
            if !draft.clarification.isEmpty { Text(draft.clarification).foregroundStyle(Palette.warning) }
            if let suggestionError { Text(suggestionError).foregroundStyle(Palette.over) }
            if requiresReview { Toggle("I checked and corrected these details", isOn: $draft.reviewed) }
        }
    }

    /// Its own builder: the Group above is already at SwiftUI's ten-child limit.
    @ViewBuilder
    private var categoryFields: some View {
            Button { picking = true } label: {
                Label(draft.category?.name ?? (draft.kind == .income ? "Choose or create income category" : "Choose or create category"), systemImage: draft.category?.symbol ?? "square.grid.2x2")
            }
            // Scope and kind both partition the picker, so either move can strand the pick.
            .onChange(of: draft.scope) { _, scope in
                if !CategoryLibrary.isSelectable(draft.category, scope: scope, kind: draft.kind) { draft.category = nil }
                draft.rememberCategory = false
            }
            .onChange(of: draft.kind) { _, kind in
                if !CategoryLibrary.isSelectable(draft.category, scope: draft.scope, kind: kind) { draft.category = nil }
                draft.rememberCategory = false
            }
            .onChange(of: draft.merchant) { _, merchant in
                draft.rememberCategory = false
                if let category = CategoryLibrary.ruleCategory(merchant: merchant, scope: draft.scope, kind: draft.kind, rules: rules) { draft.category = category }
            }
            .sheet(isPresented: $picking) {
                CategoryPickerView(selection: $draft.category, scope: draft.scope, kind: draft.kind, suggestedName: draft.suggestedName, suggestedSymbol: draft.suggestedSymbol)
            }
            Button("Suggest category", systemImage: "sparkles") {
                suggesting = true
                Task {
                    defer { suggesting = false }
                    let requestedMerchant = draft.merchant
                    let requestedNote = draft.note
                    let requestedScope = draft.scope
                    let requestedKind = draft.kind
                    do {
                        let result = try await OnDeviceAI.generate(CategorySuggestion.self,
                            instructions: "Suggest the best existing category for the transaction. Only suggest a new name if no existing category fits. Choose a supported icon.",
                            data: OnDeviceAI.context(categories: CategoryLibrary.visible(categories, scope: draft.scope, kind: draft.kind)) + "\nMerchant: \(draft.merchant)\nNote: \(draft.note)")
                        guard requestedMerchant == draft.merchant, requestedNote == draft.note, requestedScope == draft.scope, requestedKind == draft.kind else { return }
                        let visible = CategoryLibrary.visible(categories, scope: draft.scope, kind: draft.kind)
                        draft.category = CategoryLibrary.ruleCategory(merchant: draft.merchant, scope: draft.scope, kind: draft.kind, rules: rules)
                            ?? DraftResolver.category(named: result.name, in: visible) ?? CategoryLibrary.similar(result.name, in: visible).first
                        draft.suggestedName = draft.category == nil ? String(result.name.prefix(60)) : ""
                        draft.suggestedSymbol = CategoryLibrary.symbols.contains(result.symbol) ? result.symbol : "cart"
                        if draft.category == nil { picking = true }
                    } catch { suggestionError = error.localizedDescription }
                }
            }.disabled(suggesting)
            // Merchant rules only steer spending, so income never offers to remember one.
            if draft.kind == .expense, !draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.category != nil {
                Toggle("Remember this merchant\u{2019}s category", isOn: $draft.rememberCategory)
                Text("Saving with this enabled creates or replaces your rule for this merchant in this scope.").font(.caption)
            }
    }
}
