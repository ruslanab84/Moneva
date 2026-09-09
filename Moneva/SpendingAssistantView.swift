import SwiftUI
import SwiftData
import FoundationModels

struct SpendingAssistantView: View {
    let scope: Scope
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var transactions: [Transaction]
    @Query private var categories: [SpendingCategory]
    @Query private var budgets: [Budget]
    @Query private var subscriptions: [Subscription]
    @State private var question = ""
    @State private var filter: SpendingFilter?
    @State private var busy = false
    @State private var error: String?
    @State private var selectedFacts: [SpendingFact] = []
    @State private var typedFactIDs: Set<Int> = []
    @State private var source: SpendingFact?
    @State private var askAnswer: String?
    @State private var task: Task<Void, Never>?
    @State private var period: SearchPeriod = .thisMonth
    @State private var merchant = ""
    @State private var category: SpendingCategory?
    @State private var currency = ""
    @State private var kind = "expense"
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var picking = false

    private var matches: [Transaction] { filter?.results(transactions) ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ask about \(scope.title.lowercased()) spending") {
                    TextField("Restaurant expenses from last weekend", text: $question, axis: .vertical)
                    Button("Search", systemImage: "magnifyingglass") { run(explain: false) }.disabled(busy || question.isEmpty)
                    Button("Explain spending or budgets", systemImage: "sparkles") { run(explain: true) }.disabled(busy)
                    if busy { ProgressView("Reading your request…") }
                    if let reason = TransactionDrafter.unavailableReason { Text(reason).font(.caption) }
                    if let error { Text(error).foregroundStyle(Palette.over) }
                }
                if let askAnswer {
                    Section("Answer") { Text(askAnswer) }
                }
                Section {
                    DisclosureGroup("Manual search filters") {
                        Picker("Period", selection: $period) {
                            ForEach(SearchPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if period == .custom {
                            DatePicker("From", selection: $start, displayedComponents: .date)
                            DatePicker("Through", selection: $end, displayedComponents: .date)
                        }
                        TextField("Merchant contains", text: $merchant)
                        Button(category?.name ?? String(localized: "Any category")) { picking = true }
                        if category != nil { Button("Clear category") { category = nil } }
                        Picker("Currency", selection: $currency) {
                            Text("All, totaled separately").tag("")
                            ForEach(Money.pickerCodes, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Kind", selection: $kind) {
                            Text("Expenses").tag("expense")
                            Text("Income").tag("income")
                            Text("Both").tag("all")
                        }
                        TextField("Minimum transaction amount", text: $minimum).keyboardType(.decimalPad)
                        TextField("Maximum transaction amount", text: $maximum).keyboardType(.decimalPad)
                        Button("Apply filters") { applyManual() }.disabled(busy)
                    }
                    Button("Show calculated spending report") {
                        typedFactIDs = []
                        selectedFacts = SpendingReport.facts(transactions: transactions, categories: categories, budgets: budgets, subscriptions: subscriptions, scope: scope)
                    }.disabled(busy)
                }
                if let filter {
                    Section("Validated filters") {
                        Text("\(scope.title) · \(filter.kind?.title ?? "Expense and income") · \(filter.currency ?? "Currencies kept separate")")
                        if let range = filter.range { Text("\(range.lowerBound.formatted(date: .abbreviated, time: .omitted)) – \(range.upperBound.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))") }
                        if let category = filter.category { Text("Category: \(category.name). Totals include only this category’s allocation.") }
                        if !filter.merchant.isEmpty { Text("Merchant contains: \(filter.merchant)") }
                        if let minimum = filter.minimum { Text("Minimum: \(minimum.description)") }
                        if let maximum = filter.maximum { Text("Maximum: \(maximum.description)") }
                    }
                    Section("\(matches.count) matching transactions") {
                        ForEach(Set(matches.map(\.currency)).sorted(), id: \.self) { code in
                            ForEach(TransactionKind.allCases) { kind in
                                let total = matches.filter { $0.currency == code && $0.kind == kind }.reduce(Decimal.zero) { $0 + filter.amount($1) }
                                LabeledContent("\(kind.title) · \(code)", value: total.money(code))
                            }
                        }
                        ForEach(matches) { tx in
                            NavigationLink { TransactionEditView(transaction: tx) } label: { TransactionRow(transaction: tx) }
                        }
                        if matches.isEmpty { Text("No matching records.") }
                    }
                }
                if !selectedFacts.isEmpty {
                    Section("Calculated explanations") {
                        Text("This month is incomplete. Missing history may make comparisons incomplete. Each amount comes from stored records; currencies are kept separate.").font(.footnote)
                        ForEach(selectedFacts) { fact in
                            Button { source = fact } label: {
                                HStack(spacing: 10) {
                                    if let category = fact.category { CategoryBadge(category: category, size: 28) }
                                    TypewriterText(text: fact.text, animate: !typedFactIDs.contains(fact.id)).foregroundStyle(Palette.ink)
                                }
                            }
                            .onAppear { typedFactIDs.insert(fact.id) }
                        }
                    }
                }
            }
            .navigationTitle("Search & explanations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $picking) { CategoryPickerView(selection: $category, scope: scope) }
            .sheet(item: $source) { fact in
                NavigationStack {
                    List {
                        Text(fact.text)
                        ForEach(fact.transactions) { tx in
                            NavigationLink { TransactionEditView(transaction: tx) } label: { TransactionRow(transaction: tx) }
                        }
                        if fact.transactions.isEmpty { Text("Source: the calculated report and subscription schedules for this scope.") }
                    }.navigationTitle("Source records")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { source = nil } } }
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func run(explain: Bool) {
        busy = true
        error = nil
        filter = nil
        askAnswer = nil
        selectedFacts = []
        typedFactIDs = []
        task = Task {
            defer { busy = false }
            do {
                if explain {
                    let service = FinancialToolService(context: modelContext, scope: scope, currency: currency.isEmpty ? Money.code : currency)
                    askAnswer = try await FinancialToolRegistry.answer(question: question.isEmpty ? "Summarize my income and expenses this month" : question, service: service)
                } else {
                    let result = try await OnDeviceAI.generate(DraftedSearch.self,
                        instructions: "Convert the question into narrow transaction filters. Prefer named period presets for relative dates. Custom dates are inclusive. Use only existing categories. Default kind is expense. Do not silently ignore unsupported or ambiguous conditions: ask for clarification. Never write a database query.",
                        data: OnDeviceAI.context(categories: CategoryLibrary.visible(categories, scope: scope)) + "\nActive scope: \(scope.rawValue)\nQuestion: \(question)")
                    filter = try SpendingSearch.resolve(result, categories: categories, scope: scope)
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func applyManual() {
        let calendar = Calendar.current
        func date(_ date: Date) -> DraftDate {
            DraftDate(offsetDays: nil, year: calendar.component(.year, from: date), month: calendar.component(.month, from: date), day: calendar.component(.day, from: date))
        }
        do {
            filter = try SpendingSearch.resolve(DraftedSearch(period: period, start: date(start), end: date(end), category: category?.name ?? "", merchant: merchant, minimum: minimum, maximum: maximum, currency: currency, scope: scope.rawValue, kind: kind, clarification: ""), categories: categories, scope: scope)
            error = nil
        } catch { filter = nil; self.error = error.localizedDescription }
    }
}

