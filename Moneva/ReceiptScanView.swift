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
    @Query private var rules: [MerchantCategoryRule]
    @State private var receipt = Receipt()
    @State private var pickingItem: ReceiptItem?
    @State private var image: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var scanning = false
    @State private var receivedCameraImage = false
    @State private var initializedScope = false
    @State private var choosingMode = false
    @State private var busy = false
    @State private var splitAttempted = false
    @State private var retainImage = false
    @State private var error: String?
    @State private var ocr = ""
    @State private var duplicateWarning = false
    @State private var saved = false
    @State private var task: Task<Void, Never>?
    @State private var savedElsewhere: String?

    private var canSave: Bool { !busy && !saved && !choosingMode && receipt.canSave }

    var body: some View {
        NavigationStack {
            Form {
                captureSection
                Section {
                    Text(receipt.mode == .single ? "Assign the full receipt to one category." : "Review each item. Category amounts and percentages update as you edit.")
                        .font(.caption)
                }
                .disabled(busy || choosingMode)
                .listRowBackground(Palette.card)
                Section {
                    AmountHero(draft: $receipt.draft, allowKind: false, eyebrow: "Reviewed receipt total")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                .disabled(busy)
                Section {
                    DraftFields(draft: $receipt.draft, allowKind: false, showsAmount: false, showsCategory: receipt.mode == .single)
                }
                .listRowBackground(Palette.card)
                .disabled(busy)
                if receipt.mode == .split {
                    ReceiptBreakdownSection(breakdown: receipt.breakdown, total: receipt.draft.amount,
                        remaining: receipt.remaining, currency: receipt.draft.currency)
                    Section {
                        ForEach($receipt.items) { $item in
                            ReceiptItemRow(item: $item, currency: receipt.draft.currency) { pickingItem = item }
                        }
                        .onDelete { receipt.items.remove(atOffsets: $0); receipt.draft.reviewed = false }
                        Button("Add missing item", systemImage: "plus") {
                            receipt.items.append(ReceiptItem())
                            receipt.draft.reviewed = false
                        }
                        Text("Check every line, including excluded summaries. Add missing items or adjustments; swipe to delete incorrect rows. Amounts are printed line totals, not unit prices.")
                            .font(.caption)
                    } header: { Text("Line items") }
                    .disabled(busy)
                    .listRowBackground(Palette.card)
                }
                Section {
                    Button("Confirm and save one expense") {
                        if ReceiptMath.duplicates(receipt.draft, in: transactions).isEmpty { save() } else { duplicateWarning = true }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .disabled(!canSave)
                    if !receipt.canSave {
                        Text(receipt.mode == .split
                            ? "Review all lines and receipt details, select valid categories, and match the printed total to save."
                            : "Enter a valid amount, choose a category, and confirm you checked the details to save.")
                            .font(.caption).foregroundStyle(Palette.warning)
                    }
                }
                .listRowBackground(Palette.card)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .tint(Palette.accent)
            .disabled(saved)
            .navigationTitle("Receipt review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { task?.cancel(); dismiss() }.foregroundStyle(Palette.inkMuted)
                }
            }
            .onAppear {
                if !initializedScope {
                    receipt.draft.scope = Scope(rawValue: scopeRaw) ?? .personal
                    initializedScope = true
                }
            }
            .fullScreenCover(isPresented: $scanning, onDismiss: {
                if receivedCameraImage { choosingMode = true; receivedCameraImage = false }
            }) {
                DocumentScanner(onScan: { prepare($0); receivedCameraImage = true }, onError: { error = $0 }).ignoresSafeArea()
            }
            .onChange(of: photo) { _, photo in
                guard let photo else { return }
                task?.cancel()
                busy = true
                task = Task {
                    defer { busy = false }
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                            error = "Could not open this image. Choose another image."
                            return
                        }
                        try Task.checkCancellation()
                        prepare(image)
                        choosingMode = true
                    } catch is CancellationError {} catch { self.error = "Could not import this image. Try another image or enter the total manually." }
                }
            }
            .confirmationDialog("How would you like to categorize this receipt?", isPresented: $choosingMode, titleVisibility: .visible) {
                Button("Single category — full receipt total") { receipt.mode = .single; process() }
                Button("Split by category — individual items") { receipt.mode = .split; process() }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: receipt.mode) { _, mode in
                receipt.draft.reviewed = false
                receipt.draft.rememberCategory = false
                if mode == .split && !ocr.isEmpty && !splitAttempted && !busy {
                    busy = true
                    task = Task { defer { busy = false }; await categorize() }
                }
            }
            .onChange(of: receipt.draft.scope) { _, scope in
                receipt.draft.reviewed = false
                receipt.draft.rememberCategory = false
                if !CategoryLibrary.isSelectable(receipt.draft.category, scope: scope) { receipt.draft.category = nil }
                for index in receipt.items.indices {
                    if !CategoryLibrary.isSelectable(receipt.items[index].category, scope: scope) {
                        receipt.items[index].category = nil
                        receipt.items[index].reviewed = false
                    }
                }
            }
            .onChange(of: receipt.draft.currency) { _, _ in
                receipt.draft.reviewed = false
                for index in receipt.items.indices { receipt.items[index].reviewed = false }
            }
            .sheet(item: $pickingItem) { item in
                if let index = receipt.items.firstIndex(where: { $0.id == item.id }) {
                    CategoryPickerView(selection: $receipt.items[index].category, scope: receipt.draft.scope)
                }
            }
            .confirmationDialog("Possible duplicate receipt", isPresented: $duplicateWarning, titleVisibility: .visible) {
                Button("Save another copy") { save() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("An expense with this merchant, date, currency and total already exists. Save only if this is a different purchase.") }
            .alert("Receipt saved", isPresented: Binding(get: { savedElsewhere != nil }, set: { if !$0 { savedElsewhere = nil } })) {
                Button("OK") { dismiss() }
            } message: { Text(savedElsewhere ?? "") }
            .onDisappear { task?.cancel() }
        }
    }

    private var captureSection: some View {
        Section {
            if VNDocumentCameraViewController.isSupported {
                Button("Scan with camera", systemImage: "doc.viewfinder") {
                    DispatchQueue.main.async { scanning = true }
                }.disabled(busy)
            }
            PhotosPicker(selection: $photo, matching: .images) { Label("Import receipt image", systemImage: "photo") }.disabled(busy)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300).accessibilityLabel("Receipt preview")
                Toggle("Keep this receipt image", isOn: $retainImage)
                if ocr.isEmpty && !busy { Button("Read receipt") { choosingMode = true } }
            }
            Text("Images stay on this iPhone. Keep image is off by default. Manual entry is always available.").font(.caption)
            if busy { ProgressView("Reading receipt on device…") }
            if let error { Text(error).foregroundStyle(Palette.over) }
            if !ocr.isEmpty { DisclosureGroup("Recognized text") { Text(ocr).textSelection(.enabled) } }
        } header: { Eyebrow("Receipt") }
        .listRowBackground(Palette.card)
    }

    private func prepare(_ image: UIImage) {
        self.image = image
        receipt = Receipt(draft: TransactionDraft(scope: receipt.draft.scope, source: .receipt))
        retainImage = false
        splitAttempted = false
        error = nil
        ocr = ""
    }

    private func process() {
        guard let image, !busy else { return }
        busy = true
        task = Task {
            defer { busy = false }
            do {
                let rows = try await ReceiptText.read(image)
                try Task.checkCancellation()
                ocr = rows.map(\.text).joined(separator: "\n")
                receipt.items = ReceiptText.items(from: rows)
                do {
                    let visible = CategoryLibrary.visible(categories, scope: receipt.draft.scope)
                    let result = try await OnDeviceAI.generate(DraftedReceipt.self,
                        instructions: "Extract one expense using only the printed final paid total. Never use subtotal, tendered cash or change, and never sum items, taxes or discounts to produce the total. Also extract every printed line item with its own amount and best existing category; leave items empty if the receipt has no readable line items. Use only a calendar date printed on the receipt, as year, month and day; never a relative day offset and never today's date as a guess. Missing date/currency/total must remain empty or nil and require clarification. Suggest one existing category for the whole receipt; leave it empty if unclear.",
                        data: OnDeviceAI.context(categories: visible) + "\nReceipt text:\n" + ocr)
                    // A printed receipt never says "yesterday" — only an explicit printed date counts here.
                    let date = DraftResolver.date(result.date, allowRelative: false)
                    let currency = result.currency.uppercased()
                    receipt.draft.amount = Money.parse(result.total) ?? 0
                    receipt.draft.currency = Money.pickerCodes.contains(currency) ? currency : Money.code
                    receipt.draft.merchant = DraftResolver.grounded(result.merchant, in: ocr)
                    receipt.draft.date = date ?? .now
                    receipt.draft.clarification = [result.clarification, date == nil ? "Check the purchase date." : "", Money.pickerCodes.contains(currency) ? "" : "Choose the receipt currency.", "Verify the printed final total against the preview."].filter { !$0.isEmpty }.joined(separator: "\n")
                    // Rule, then classifier, both outrank the model's own category guess — the receipt
                    // path previously trusted only the model's raw name here, skipping both.
                    let classification = await CategoryClassifier.classify(merchant: receipt.draft.merchant, scope: receipt.draft.scope, categories: visible, container: context.container)
                    let resolution = DraftResolver.resolveCategory(merchant: receipt.draft.merchant, scope: receipt.draft.scope, kind: .expense, categories: categories, rules: rules, classification: classification)
                    receipt.draft.category = resolution.category ?? DraftResolver.category(named: result.category, in: visible)
                    receipt.draft.categoryConfident = resolution.category != nil
                    receipt.draft.categoryMargin = resolution.margin
                    // The model's own line items checked against its own total: mismatched (>1%) collapses to
                    // this single transaction (current behavior); reconciled proposes a split by category.
                    switch ReceiptMath.resolveItems(result.items, total: receipt.draft.amount, categories: visible, input: ocr) {
                    case .collapse:
                        receipt.mode = .single
                    case .split(let items):
                        receipt.items = items
                        receipt.mode = .split
                        splitAttempted = true
                    }
                } catch is CancellationError { return } catch {
                    self.error = error.localizedDescription + " Enter the receipt details manually. OCR items remain available."
                }
                if receipt.mode == .split && !splitAttempted { await categorize() }
            } catch is CancellationError {} catch {
                self.error = "Could not read this receipt. Try a clearer image or enter the details and items manually."
            }
        }
    }

    private func categorize() async {
        splitAttempted = true
        guard !receipt.items.isEmpty else { return }
        do {
            let items = try await ReceiptCategorizer.suggest(receipt.items,
                categories: CategoryLibrary.visible(categories, scope: receipt.draft.scope))
            try Task.checkCancellation()
            receipt.items = items
        } catch is CancellationError {} catch {
            self.error = error.localizedDescription + " Choose item categories manually; the scanned amounts are preserved."
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            try receipt.save(in: context, image: retainImage ? image?.jpegData(compressionQuality: 0.8) : nil)
            saved = true
            let currentScope = Scope(rawValue: scopeRaw) ?? .personal
            if receipt.draft.scope != currentScope || !Budgeting.monthRange(for: .now).contains(receipt.draft.date) {
                savedElsewhere = String(localized: "Saved to \(receipt.draft.scope.title) · \(receipt.draft.date.formatted(.dateTime.month(.wide).year())). It won't show in this month's \(currentScope.title) list.")
            } else {
                dismiss()
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct ReceiptBreakdownSection: View {
    var breakdown: [CategoryBreakdown]
    var total: Decimal
    var remaining: Decimal
    var currency: String

    var body: some View {
        Section {
            ForEach(breakdown) { group in
                DisclosureGroup {
                    ForEach(group.items) { item in
                        LabeledContent(item.name, value: item.contribution.money(currency))
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(group.allocation.category?.name ?? String(localized: "Choose category"), systemImage: group.allocation.category?.symbol ?? "questionmark.circle")
                        Text("\(group.allocation.amount.money(currency)) (\(group.fraction.map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? "—"))")
                            .monospacedDigit()
                    }
                }
            }
            LabeledContent("Printed total", value: total.money(currency))
            LabeledContent(remaining == 0 ? "Matched" : "Difference to resolve", value: remaining.money(currency))
                .foregroundStyle(remaining == 0 ? Palette.ink : Palette.warning)
            Text("Percentages use the printed total. Rounded percentages may not add to 100%. Taxes and discounts affect their assigned category.")
                .font(.caption)
        } header: { Text("Category breakdown · \(currency)") }
        .listRowBackground(Palette.card)
    }
}

struct ReceiptItemRow: View {
    @Binding var item: ReceiptItem
    var currency: String
    var pickCategory: () -> Void

    private var editSignature: String {
        "\(item.name)|\(item.amount)|\(item.kind)|\(item.alreadyIncluded)|\(String(describing: item.category?.persistentModelID))|\(item.quantity)|\(item.unitPrice)"
    }

    var body: some View {
        DisclosureGroup {
            TextField("Item description", text: $item.name)
            AmountField(title: "Printed line total", value: $item.amount, currencyCode: currency)
            Picker("Line type", selection: $item.kind) {
                ForEach(ReceiptLineKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            TextField("Quantity (reference only)", text: $item.quantity)
            TextField("Unit price (reference only)", text: $item.unitPrice)
            Toggle("Already included / summary — exclude", isOn: $item.alreadyIncluded)
            if !item.alreadyIncluded {
                Button(action: pickCategory) {
                    Label(item.category?.name ?? String(localized: "Choose category"), systemImage: item.category?.symbol ?? "square.grid.2x2")
                }
            }
            if !item.sourceText.isEmpty { Text("Scanned: \(item.sourceText)").font(.caption).textSelection(.enabled) }
            if let confidence = item.ocrConfidence {
                Text("OCR confidence: \(confidence.formatted(.percent.precision(.fractionLength(0)))). This measures text recognition, not category accuracy.").font(.caption)
            }
            Text(item.categoryConfidence == .likely ? "Category suggestion: likely (not a calibrated probability)." : "Category suggestion: uncertain — choose or verify manually.")
                .font(.caption).foregroundStyle(Palette.warning)
            if !item.uncertainty.isEmpty { Text(item.uncertainty).font(.caption) }
            Toggle("I verified this line", isOn: $item.reviewed)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name.isEmpty ? "New item" : item.name)
                Text("\(item.alreadyIncluded ? String(localized: "Excluded") : item.category?.name ?? String(localized: "Choose category")) · \(item.contribution.money(currency))")
                    .font(.caption)
                Label(item.reviewed ? "Reviewed" : "Needs review", systemImage: item.reviewed ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(item.reviewed ? Palette.inkMuted : Palette.warning)
            }
        }
        .onChange(of: editSignature) { _, _ in item.reviewed = false }
    }
}
