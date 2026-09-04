import SwiftUI
import SwiftData

struct AddTransactionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @Query(sort: \SpendingCategory.name) private var categories: [SpendingCategory]

    @State private var kind: TransactionKind
    @State private var amount: Decimal
    @State private var merchant: String
    @State private var note: String
    @State private var date: Date
    @State private var category: SpendingCategory?
    @State private var scope: Scope
    @State private var isPickingCategory = false

    /// A voice or receipt draft arrives here prefilled; the form is still the
    /// thing that saves it.
    private let isPrefilled: Bool

    init(draft: TransactionDraft? = nil) {
        _kind = State(initialValue: draft?.kind ?? .expense)
        _amount = State(initialValue: draft?.amount ?? 0)
        _merchant = State(initialValue: draft?.merchant ?? "")
        _note = State(initialValue: draft?.note ?? "")
        _date = State(initialValue: draft?.date ?? .now)
        _category = State(initialValue: draft?.category)
        _scope = State(initialValue: draft?.scope ?? .personal)
        isPrefilled = draft != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(TransactionKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    AmountField(title: "Amount", value: $amount)
                        .font(.money(.largeTitle))
                }

                Section {
                    TextField(kind == .expense ? "Merchant" : "Source", text: $merchant)
                    DatePicker("Date", selection: $date)
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.title).tag($0) }
                    }
                }

                if kind == .expense {
                    Section("Category") {
                        Button { isPickingCategory = true } label: {
                            HStack(spacing: 12) {
                                CategoryBadge(category: category, size: 32)
                                Text(category?.name ?? "Choose a category")
                                    .foregroundStyle(category == nil ? Palette.inkMuted : Palette.ink)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Palette.inkFaint)
                            }
                        }
                    }
                }

                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical)
                }
            }
            .navigationTitle(kind == .expense ? "New expense" : "New income")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(amount <= 0 || (kind == .expense && category == nil))
                }
            }
            .onAppear {
                guard !isPrefilled else { return }
                scope = Scope(rawValue: scopeRaw) ?? .personal
                if category == nil { category = CategoryLibrary.visible(categories, scope: scope).first }
            }
            .sheet(isPresented: $isPickingCategory) {
                CategoryPickerView(selection: $category, scope: scope)
            }
        }
    }

    private func save() {
        let transaction = Transaction(
            amount: amount,
            date: date,
            merchant: merchant,
            note: note,
            kind: kind,
            scope: scope,
            source: isPrefilled ? .voice : .manual,
            category: kind == .expense ? category : nil
        )
        context.insert(transaction)
        dismiss()
    }
}
