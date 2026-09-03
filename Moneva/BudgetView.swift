import SwiftUI
import SwiftData

struct BudgetView: View {
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var budgets: [Budget]
    @State private var isEditing = false

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
    private var range: Range<Date> { Budgeting.monthRange(for: .now) }
    private var budget: Budget? { budgets.first { $0.scope == scope && $0.monthStart == range.lowerBound } }
    private var monthTransactions: [Transaction] {
        transactions.filter { $0.scope == scope && range.contains($0.date) }
    }
    private var spent: Decimal { Budgeting.spent(monthTransactions, in: range, scope: scope) }

    var body: some View {
        ScreenScroll(title: range.lowerBound.formatted(.dateTime.month(.wide)), eyebrow: "Budget") {
            ScopePicker(scope: Binding(get: { scope }, set: { scopeRaw = $0.rawValue }))

            if let budget {
                totalCard(budget)
                if !budget.limits.isEmpty {
                    Eyebrow("Category limits").padding(.top, 4)
                    VStack(spacing: 16) {
                        ForEach(budget.limits.sorted { $0.amount > $1.amount }, id: \.persistentModelID) { limit in
                            limitRow(limit)
                        }
                    }
                    .monevaCard(padding: 16)
                }
                Button("Edit budget", systemImage: "slider.horizontal.3") { isEditing = true }
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)
            } else {
                EmptyHint(
                    title: "No \(scope.title.lowercased()) budget yet",
                    message: "Give the month a total limit, then add per-category limits if you want them.",
                    symbol: "chart.pie"
                )
                Button("Create budget", systemImage: "plus") { isEditing = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
        .sheet(isPresented: $isEditing) {
            BudgetEditor(monthStart: range.lowerBound, scope: scope, budget: budget)
        }
    }

    @ViewBuilder
    private func totalCard(_ budget: Budget) -> some View {
        let progress = Budgeting.progress(spent: spent, limit: budget.total)
        let state = Budgeting.LimitState(progress: progress)
        let remaining = max(budget.total - spent, 0)

        VStack(alignment: .leading, spacing: 13) {
            Text("\(remaining.money()) left")
                .font(.money(.largeTitle))
                .foregroundStyle(Palette.ink)
            ProgressBar(progress: progress, tint: color(state), height: 10)
            HStack {
                Text("\(spent.money()) spent of \(budget.total.money())")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(color(state))
            }
            if let projection = Budgeting.projectedMonthTotal(spent: spent, now: .now) {
                Divider().overlay(Palette.line)
                Label("On this pace you finish the month around \(projection.money()).", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted)
            }
        }
        .monevaCard()
    }

    @ViewBuilder
    private func limitRow(_ limit: BudgetLimit) -> some View {
        let used = monthTransactions
            .filter { $0.kind == .expense && $0.category?.persistentModelID == limit.category?.persistentModelID }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let progress = Budgeting.progress(spent: used, limit: limit.amount)
        let state = Budgeting.LimitState(progress: progress)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                CategoryBadge(category: limit.category, size: 30)
                Text(limit.category?.name ?? "Uncategorised")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("\(used.money()) / \(limit.amount.money())")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(state == .ok ? Palette.inkMuted : color(state))
            }
            ProgressBar(progress: progress, tint: color(state))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(limit.category?.name ?? "Uncategorised"), \(used.money()) of \(limit.amount.money()), \(Int(progress * 100)) percent")
    }

    private func color(_ state: Budgeting.LimitState) -> Color {
        switch state {
        case .ok: Palette.accent
        case .nearingLimit: Palette.warning
        case .atLimit: Palette.over
        }
    }
}

struct BudgetEditor: View {
    let monthStart: Date
    let scope: Scope
    let budget: Budget?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendingCategory.name) private var categories: [SpendingCategory]

    @State private var total: Decimal = 0
    @State private var limits: [PersistentIdentifier: Decimal] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("Monthly total") {
                    AmountField(title: "Total limit", value: $total)
                        .font(.money(.title2))
                }
                Section("Category limits") {
                    ForEach(categories, id: \.persistentModelID) { category in
                        HStack {
                            CategoryBadge(category: category, size: 30)
                            Text(category.name)
                            Spacer()
                            AmountField(title: "None", value: binding(for: category))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                        }
                    }
                }
            }
            .navigationTitle(budget == nil ? "New budget" : "Edit budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(total <= 0) }
            }
            .onAppear(perform: load)
        }
    }

    private func binding(for category: SpendingCategory) -> Binding<Decimal> {
        Binding(
            get: { limits[category.persistentModelID] ?? 0 },
            set: { limits[category.persistentModelID] = $0 }
        )
    }

    private func load() {
        guard let budget else { return }
        total = budget.total
        for limit in budget.limits {
            if let id = limit.category?.persistentModelID { limits[id] = limit.amount }
        }
    }

    private func save() {
        let target = budget ?? {
            let fresh = Budget(monthStart: monthStart, total: total, scope: scope)
            context.insert(fresh)
            return fresh
        }()
        target.total = total

        // Rebuild the limit set from the form: simpler than diffing, and the
        // list is six rows long.
        for limit in target.limits { context.delete(limit) }
        target.limits = []
        for category in categories {
            let amount = limits[category.persistentModelID] ?? 0
            guard amount > 0 else { continue }
            let limit = BudgetLimit(amount: amount, category: category)
            limit.budget = target
            context.insert(limit)
            target.limits.append(limit)
        }
        dismiss()
    }
}
