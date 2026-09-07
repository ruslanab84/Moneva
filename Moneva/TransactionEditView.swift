import SwiftUI
import SwiftData

/// Full edit sheet for an existing transaction. Fields stage in local
/// @State so Cancel truly discards; Save writes the whole batch back to the
/// model in one `withAnimation`, so the chart/list/totals redraw together.
struct TransactionEditView: View {
    let transaction: Transaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var kind: TransactionKind
    @State private var amount: Decimal
    @State private var merchant: String
    @State private var note: String
    @State private var date: Date
    @State private var category: SpendingCategory?
    @State private var picking = false
    @State private var confirmingDelete = false

    private var scope: Scope { transaction.scope }
    private var currency: String { transaction.currency }
    private var isSplit: Bool { !transaction.allocations.isEmpty }

    init(transaction: Transaction) {
        self.transaction = transaction
        _kind = State(initialValue: transaction.kind)
        _amount = State(initialValue: transaction.amount)
        _merchant = State(initialValue: transaction.merchant)
        _note = State(initialValue: transaction.note)
        _date = State(initialValue: transaction.date)
        _category = State(initialValue: transaction.category)
    }

    private var canSave: Bool {
        Money.valid(amount, currency: currency) && (isSplit || CategoryLibrary.isSelectable(category, scope: scope, kind: kind))
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(TransactionKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { _, newKind in
                    if !CategoryLibrary.isSelectable(category, scope: scope, kind: newKind) { category = nil }
                }
                AmountField(title: "Amount", value: $amount, currencyCode: currency)
            }
            .disabled(isSplit)
            .listRowBackground(Palette.card)

            Section {
                Button {
                    picking = true
                } label: {
                    Label(category?.name ?? "Choose category", systemImage: category?.symbol ?? "square.grid.2x2")
                }
                .disabled(isSplit)
                TextField("Merchant or source", text: $merchant)
                DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                TextField("Note", text: $note, axis: .vertical)
            }
            .listRowBackground(Palette.card)

            if isSplit {
                Section("Saved category split") {
                    ForEach(transaction.allocations) { allocation in
                        LabeledContent(allocation.category?.name ?? "Deleted category", value: allocation.amount.money(currency))
                    }
                    Text("The total, type and categories are fixed for this saved split. To replace the split, delete this expense and review the receipt again.")
                        .font(.caption)
                }
                .listRowBackground(Palette.card)
            }

            if let data = transaction.receiptImage, let image = UIImage(data: data) {
                Section("Receipt") {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Saved receipt")
                }
                .listRowBackground(Palette.card)
            }
            if let data = transaction.receiptItems, let items = try? JSONDecoder().decode([SavedReceiptItem].self, from: data), !items.isEmpty {
                Section("Receipt items") {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading) {
                            Text("\(item.name) · \(item.kind.rawValue) · \(item.amount.money(currency))")
                            if !item.quantity.isEmpty || !item.unitPrice.isEmpty { Text("Quantity: \(item.quantity) · Unit price: \(item.unitPrice)").font(.caption) }
                            if item.alreadyIncluded { Text("Included in other lines; not added again.").font(.caption) }
                        }
                    }
                }
                .listRowBackground(Palette.card)
            }

            Section {
                Button("Delete transaction", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
            }
            .listRowBackground(Palette.card)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.ground)
        .tint(Palette.accent)
        .navigationTitle("Edit transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.foregroundStyle(Palette.inkMuted)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(!canSave)
            }
        }
        .sheet(isPresented: $picking) {
            CategoryPickerView(selection: $category, scope: scope, kind: kind)
        }
        .confirmationDialog("Delete this transaction?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        }
    }

    private func save() {
        withAnimation(.snappy(duration: 0.35)) {
            transaction.kind = kind
            transaction.amount = amount
            transaction.merchant = merchant
            transaction.note = note
            transaction.date = date
            transaction.category = category
        }
        dismiss()
    }

    private func delete() {
        withAnimation(.snappy(duration: 0.35)) {
            context.delete(transaction)
        }
        dismiss()
    }
}
