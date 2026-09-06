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
    @State private var image: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var scanning = false
    @State private var busy = false
    @State private var retainImage = false
    @State private var error: String?
    @State private var ocr = ""
    @State private var duplicateWarning = false
    @State private var saved = false
    @State private var task: Task<Void, Never>?

    private var canSave: Bool { !busy && !saved && draft.canSave }

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                } header: { Eyebrow("Receipt") }
                .listRowBackground(Palette.card)
                Section {
                    AmountHero(draft: $draft, allowKind: false, eyebrow: "Reviewed receipt total")
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                .disabled(busy)
                Section { DraftFields(draft: $draft, allowKind: false, showsAmount: false) }
                    .listRowBackground(Palette.card)
                    .disabled(busy)
                Section {
                    Button {
                        if ReceiptMath.duplicates(draft, in: transactions).isEmpty { save() } else { duplicateWarning = true }
                    } label: {
                        Text("Confirm and save one expense")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .disabled(!canSave)
                    .listRowBackground(Palette.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .tint(Palette.accent)
            .disabled(saved)
            .navigationTitle("Receipt review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.inkMuted)
                }
            }
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
                    instructions: "Extract one expense from this receipt using only the printed final paid total. Never use subtotal, tendered cash or change, and never sum items, taxes or discounts. Missing date/currency/total must remain empty or nil and require clarification. Suggest one existing category for the whole receipt; leave it empty if unclear.",
                    data: OnDeviceAI.context(categories: visible) + "\nReceipt text:\n" + ocr)
                let date = DraftResolver.date(result.date)
                let currency = result.currency.uppercased()
                draft.amount = Money.parse(result.total) ?? 0
                draft.currency = Money.pickerCodes.contains(currency) ? currency : Money.code
                draft.merchant = DraftResolver.grounded(result.merchant, in: ocr)
                draft.date = date ?? .now
                draft.clarification = [result.clarification, date == nil ? "Check the purchase date." : "", Money.pickerCodes.contains(currency) ? "" : "Choose the receipt currency.", "Verify the printed final total against the preview."].filter { !$0.isEmpty }.joined(separator: "\n")
                draft.category = DraftResolver.category(named: result.category, in: visible)
            } catch is CancellationError {} catch { self.error = error.localizedDescription + " Enter the reviewed total manually, or scan again." }
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            try DraftStore.save([draft], in: context,
                receiptImage: retainImage ? image?.jpegData(compressionQuality: 0.8) : nil)
            saved = true
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
