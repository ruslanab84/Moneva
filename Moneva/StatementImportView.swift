import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// CSV / bank-statement import. Same contract as voice and receipt capture:
/// the file only ever produces drafts, the user ticks what is real, and
/// `DraftStore.save` is the one door into the store.
struct StatementImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Query private var categories: [SpendingCategory]
    @Query private var accounts: [Account]
    @Query private var saved: [Transaction]

    @State private var isPicking = false
    @State private var fileName = ""
    @State private var header: [String] = []
    @State private var lines: [[String]] = []
    @State private var hasHeader = true
    @State private var mapping: StatementImport.Mapping?
    @State private var rows: [StatementImport.Row] = []
    @State private var skipped: Set<UUID> = []
    @State private var matched: [UUID: SpendingCategory] = [:]
    @State private var fallback: SpendingCategory?
    @State private var account: Account?
    @State private var classifying = false
    @State private var error: String?

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
    private var chosen: [StatementImport.Row] { rows.filter { !skipped.contains($0.id) } }
    private var canImport: Bool { !chosen.isEmpty && !classifying && fallback != nil }

    var body: some View {
        Form {
            Section {
                Button(fileName.isEmpty ? "Choose a CSV file" : fileName, systemImage: "doc.badge.plus") { isPicking = true }
            } footer: {
                Text("Export a statement from your bank as CSV, then pick it here. Nothing leaves the device.")
            }

            if let mapping, !lines.isEmpty {
                columnSection(mapping)
                categorySection
                rowSection
            }
        }
        .navigationTitle("Import statement")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text]) { result in
            load(result)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") { save() }.disabled(!canImport)
            }
        }
        .alert("Import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Sections

    private func columnSection(_ mapping: StatementImport.Mapping) -> some View {
        Section {
            Toggle("First row is a header", isOn: $hasHeader)
            columnPicker("Date", index: Binding(get: { self.mapping?.date ?? 0 }, set: { self.mapping?.date = $0 }))
            columnPicker("Description", index: Binding(get: { self.mapping?.merchant ?? 0 }, set: { self.mapping?.merchant = $0 }))
            columnPicker("Amount", index: Binding(get: { self.mapping?.amount ?? 0 }, set: { self.mapping?.amount = $0 }))
            Picker("Currency column", selection: Binding(get: { self.mapping?.currency ?? -1 }, set: { self.mapping?.currency = $0 < 0 ? nil : $0 })) {
                Text("\(currencyCode) for every row").tag(-1)
                ForEach(header.indices, id: \.self) { Text(label(header[$0], $0)).tag($0) }
            }
            Picker("Amounts", selection: Binding(get: { self.mapping?.sign ?? .signed }, set: { self.mapping?.sign = $0 })) {
                Text("Minus is spending").tag(StatementImport.SignRule.signed)
                Text("All spending").tag(StatementImport.SignRule.allExpense)
                Text("All income").tag(StatementImport.SignRule.allIncome)
            }
        } header: {
            Text("Columns")
        } footer: {
            Text("A statement with separate Debit and Credit columns imports twice — once per column.")
        }
        .onChange(of: self.mapping) { rebuild() }
        .onChange(of: hasHeader) { rebuild() }
    }

    private func columnPicker(_ title: LocalizedStringKey, index: Binding<Int>) -> some View {
        Picker(title, selection: index) {
            ForEach(header.indices, id: \.self) { Text(label(header[$0], $0)).tag($0) }
        }
    }

    private var categorySection: some View {
        Section {
            NavigationLink {
                CategoryPickerView(selection: $fallback, scope: scope)
            } label: {
                LabeledContent("Category for the rest") { Text(fallback?.name ?? "Pick one").foregroundStyle(Palette.inkMuted) }
            }
            if !accounts.isEmpty {
                Picker("Account", selection: $account) {
                    Text("None").tag(Account?.none)
                    ForEach(Accounts.visible(accounts), id: \.persistentModelID) { Text($0.name).tag(Account?.some($0)) }
                }
            }
        } header: {
            Text("Categories")
        } footer: {
            Text(classifying ? "Matching merchants to your categories…" : "Known merchants are matched to your own categories. Everything else lands in the category you pick here.")
        }
    }

    private var rowSection: some View {
        Section {
            ForEach(rows) { row in
                Button {
                    if skipped.contains(row.id) { skipped.remove(row.id) } else { skipped.insert(row.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: skipped.contains(row.id) ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(skipped.contains(row.id) ? Palette.inkMuted : Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.merchant.isEmpty ? "No description" : row.merchant).lineLimit(1)
                            Text("\(row.date.formatted(date: .abbreviated, time: .omitted)) · \((matched[row.id] ?? fallback)?.name ?? "—")")
                                .font(.caption).foregroundStyle(Palette.inkMuted)
                        }
                        Spacer()
                        Text(row.amount.money(row.currency))
                            .foregroundStyle(row.kind == .income ? Palette.accent : Palette.ink)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            LabeledContent("\(rows.count) rows found") { Text("\(chosen.count) selected") }
        } footer: {
            Text("Rows that look like transactions you already have are unticked. Unreadable rows were skipped.")
        }
    }

    private func label(_ name: String, _ index: Int) -> String {
        name.isEmpty ? "Column \(index + 1)" : name
    }

    // MARK: - Work

    private func load(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let text = StatementImport.text(data) else { throw Failure.unreadable }
            let fields = StatementImport.fields(text, delimiter: StatementImport.delimiter(text))
            guard let first = fields.first else { throw Failure.empty }
            fileName = url.lastPathComponent
            lines = fields
            header = first
            let guess = StatementImport.guessMapping(header: first)
            hasHeader = guess != nil
            mapping = guess ?? StatementImport.Mapping(date: 0, merchant: min(1, first.count - 1), amount: max(0, first.count - 1), currency: nil)
            rebuild()
        } catch {
            self.error = (error as? Failure)?.errorDescription ?? error.localizedDescription
        }
    }

    private func rebuild() {
        guard let mapping else { return }
        rows = StatementImport.rows(lines, mapping: mapping, defaultCurrency: currencyCode, skipFirst: hasHeader)
        skipped = Set(rows.filter { row in saved.contains { StatementImport.isDuplicate(row, of: $0) } }.map(\.id))
        matched = [:]
        if rows.isEmpty { error = Failure.noRows.errorDescription }
        classify()
    }

    /// One classification per distinct merchant, not per row: a statement is
    /// mostly the same dozen shops over and over.
    private func classify() {
        let expenses = CategoryLibrary.visible(categories, scope: scope, kind: .expense)
        let incomes = CategoryLibrary.visible(categories, scope: scope, kind: .income)
        guard !expenses.isEmpty || !incomes.isEmpty else { return }
        let container = context.container
        let pending = rows
        classifying = true
        Task {
            var byMerchant: [String: SpendingCategory] = [:]
            var result: [UUID: SpendingCategory] = [:]
            for row in pending {
                let key = "\(row.kind.rawValue)|\(CategoryLibrary.fold(row.merchant))"
                if let known = byMerchant[key] { result[row.id] = known; continue }
                guard !CategoryLibrary.fold(row.merchant).isEmpty else { continue }
                let pool = row.kind == .income ? incomes : expenses
                if let match = await CategoryClassifier.classify(merchant: row.merchant, scope: scope, categories: pool, container: container) {
                    byMerchant[key] = match.category
                    result[row.id] = match.category
                }
            }
            await MainActor.run {
                guard rows.map(\.id) == pending.map(\.id) else { return }
                matched = result
                classifying = false
            }
        }
    }

    private func save() {
        guard let fallback else { return }
        let drafts: [TransactionDraft] = chosen.compactMap { row in
            var draft = TransactionDraft()
            draft.kind = row.kind
            draft.amount = row.amount
            draft.merchant = row.merchant
            draft.date = row.date
            draft.currency = row.currency
            draft.scope = scope
            draft.account = Accounts.holder(account, currency: row.currency)
            draft.source = .manual
            draft.category = matched[row.id] ?? (CategoryLibrary.isSelectable(fallback, scope: scope, kind: row.kind) ? fallback : nil)
            draft.reviewed = true
            return draft.canSave ? draft : nil
        }
        guard !drafts.isEmpty else { error = Failure.nothingValid.errorDescription; return }
        do {
            try DraftStore.save(drafts, in: context)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private enum Failure: LocalizedError {
        case unreadable, empty, noRows, nothingValid
        var errorDescription: String? {
            switch self {
            case .unreadable: return String(localized: "This file is not text Moneva can read. Export it as CSV.")
            case .empty: return String(localized: "That file has no rows.")
            case .noRows: return String(localized: "No rows could be read with these columns. Check the date and amount columns.")
            case .nothingValid: return String(localized: "None of the selected rows could be saved. Check the currency and the category.")
            }
        }
    }
}
