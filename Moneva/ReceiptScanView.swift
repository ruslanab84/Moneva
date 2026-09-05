import SwiftUI
import SwiftData
import PhotosUI
import VisionKit

struct ReceiptScanView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @Query private var categories: [SpendingCategory]
    @Query private var transactions: [Transaction]
    @State private var draft = TransactionDraft(source: .receipt)
    @State private var items: [ReceiptItem] = []
    @State private var image: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var scanning = false
    @State private var busy = false
    @State private var split = false
    @State private var retainImage = false
    @State private var error: String?
    @State private var ocr = ""
    @State private var selectingIDs: Set<UUID> = []
    @State private var picking = false
    @State private var duplicateWarning = false
    @State private var saved = false
    @State private var task: Task<Void, Never>?

    private var allocations: [ReceiptAllocation] { ReceiptMath.allocations(items) }
    private var prepared: TransactionDraft {
        var result = draft
        if split { result.category = allocations.first(where: { $0.amount > 0 })?.category }
        return result
    }
    private var canSave: Bool {
        !busy && !saved && prepared.canSave && (!split || ReceiptMath.reconciled(items, total: draft.amount, currency: draft.currency, scope: draft.scope))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Receipt") {
                    if VNDocumentCameraViewController.isSupported {
                        Button("Scan with camera", systemImage: "doc.viewfinder") { scanning = true }.disabled(busy)
                    }
                    PhotosPicker(selection: $photo, matching: .images) { Label("Import receipt image", systemImage: "photo") }.disabled(busy)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300).accessibilityLabel("Receipt preview")
                        Toggle("Keep this receipt image", isOn: $retainImage)
                    }
                    Text("Images stay on this iPhone. Keep image is off by default. You can also enter a reviewed total manually.").font(.caption)
                    if busy { ProgressView("Reading receipt on device…") }
                    if let error { Text(error).foregroundStyle(Palette.over) }
                    if !ocr.isEmpty { DisclosureGroup("Recognized text") { Text(ocr).textSelection(.enabled) } }
                }
                Section("Reviewed total") { DraftFields(draft: $draft, allowKind: false) }.disabled(busy)
                Section {
                    Toggle("Split by category", isOn: $split).disabled(busy)
                    Text(split ? "Allocate every item, tax and discount. Category totals must equal the receipt total." : "Save as one expense using the reviewed total.").font(.caption)
                }
                ForEach($items) { $item in
                    Section {
                        TextField("Item name", text: $item.name)
                        Picker("Line type", selection: $item.kind) {
                            ForEach(ReceiptLineKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        AmountField(title: "Printed line amount", value: $item.amount, currencyCode: draft.currency)
                        TextField("Quantity (if printed)", text: $item.quantity)
                        TextField("Unit price (if printed)", text: $item.unitPrice)
                        Toggle("Already included in other line amounts", isOn: $item.alreadyIncluded)
                        Button(item.category?.name ?? "Choose or create category") { selectingIDs = [item.id]; picking = true }
                        if !item.uncertainty.isEmpty { Text(item.uncertainty).font(.footnote).foregroundStyle(Palette.warning) }
                        Button("Remove line", role: .destructive) { items.removeAll { $0.id == item.id } }
                    }
                }
                Section("Category subtotals") {
                    ForEach(allocations) { allocation in
                        Button {
                            selectingIDs = Set(items.filter { $0.category?.persistentModelID == allocation.category?.persistentModelID }.map(\.id))
                            picking = true
                        } label: {
                            LabeledContent(allocation.category?.name ?? "Uncategorised", value: allocation.amount.money(draft.currency))
                        }
                    }
                    let allocated = allocations.reduce(Decimal.zero) { $0 + $1.amount }
                    LabeledContent("Allocated", value: allocated.money(draft.currency))
                    if split && allocated != draft.amount {
                        Text("Difference: \((draft.amount - allocated).money(draft.currency)). Correct the lines or save as one expense.").foregroundStyle(Palette.over)
                    }
                    Button("Add item, tax or discount") { items.append(ReceiptItem()) }
                }
                Section {
                    Button(split ? "Confirm and save split receipt" : "Confirm and save one expense") {
                        if ReceiptMath.duplicates(prepared, in: transactions).isEmpty { save() } else { duplicateWarning = true }
                    }.disabled(!canSave)
                }
            }
            .disabled(saved)
            .navigationTitle("Receipt review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { draft.scope = Scope(rawValue: scopeRaw) ?? .personal }
            .fullScreenCover(isPresented: $scanning) {
                DocumentScanner(onScan: { image in process(image) }, onError: { error = $0 }).ignoresSafeArea()
            }
            .onChange(of: photo) { _, photo in
                task = Task {
                    do {
                        guard let data = try await photo?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                        process(image)
                    } catch { self.error = "Could not import this image. Try another image or enter the total manually." }
                }
            }
            .sheet(isPresented: $picking) {
                CategoryPickerView(selection: Binding(get: { items.first { selectingIDs.contains($0.id) }?.category }, set: { category in
                    for index in items.indices where selectingIDs.contains(items[index].id) { items[index].category = category }
                }), scope: draft.scope)
            }
            .confirmationDialog("Possible duplicate receipt", isPresented: $duplicateWarning, titleVisibility: .visible) {
                Button("Save another copy") { save() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("An expense with this merchant, date, currency and total already exists. Save only if this is a different purchase.") }
            .onDisappear { task?.cancel() }
        }
    }

    private func process(_ image: UIImage) {
        guard !busy else { return }
        self.image = image
        items = []
        split = false
        draft = TransactionDraft(scope: draft.scope, source: .receipt)
        retainImage = false
        busy = true
        error = nil
        ocr = ""
        task = Task {
            defer { busy = false }
            do {
                ocr = try await ReceiptText.read(image)
                let visible = CategoryLibrary.visible(categories, scope: draft.scope)
                let result = try await OnDeviceAI.generate(DraftedReceipt.self,
                    instructions: "Structure this receipt. Extract only printed values. Missing date/currency/total must remain empty or nil and require clarification. Extract line amounts without arithmetic. Include printed quantities, prices, taxes and discounts. Mark informational tax or discounts already included in line totals to prevent double counting. If line extraction fails return no items, retaining a readable total.",
                    data: OnDeviceAI.context(categories: visible) + "\nReceipt text:\n" + ocr)
                let date = DraftResolver.date(result.date)
                let currency = result.currency.uppercased()
                draft.amount = Money.parse(result.total) ?? 0
                draft.currency = Money.pickerCodes.contains(currency) ? currency : Money.code
                draft.merchant = DraftResolver.grounded(result.merchant, in: ocr)
                draft.date = date ?? .now
                draft.clarification = [result.clarification, date == nil ? "Check the purchase date." : "", Money.pickerCodes.contains(currency) ? "" : "Choose the receipt currency.", "Verify the printed total, taxes and discounts against the preview."].filter { !$0.isEmpty }.joined(separator: "\n")
                items = result.items.map {
                    ReceiptItem(name: $0.name, kind: $0.kind, amount: Money.parse($0.amount) ?? 0, quantity: $0.quantity, unitPrice: $0.unitPrice,
                        alreadyIncluded: $0.alreadyIncluded, category: DraftResolver.category(named: $0.category, in: visible),
                        uncertainty: $0.uncertainty + (Money.parse($0.amount) == nil ? " Check the line amount." : ""))
                }
                draft.category = items.first?.category
                if items.isEmpty { error = "No items were extracted. You can save one expense after reviewing the total." }
            } catch is CancellationError {} catch { self.error = error.localizedDescription + " Enter the reviewed total manually, or scan again." }
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            let savedItems = items.map { SavedReceiptItem(name: $0.name, kind: $0.kind, amount: $0.amount, quantity: $0.quantity, unitPrice: $0.unitPrice, alreadyIncluded: $0.alreadyIncluded, category: $0.category?.name) }
            try DraftStore.save([prepared], in: context, allocations: split ? allocations.filter { $0.amount > 0 } : [],
                receiptImage: retainImage ? image?.jpegData(compressionQuality: 0.8) : nil,
                receiptItems: try JSONEncoder().encode(savedItems))
            saved = true
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
