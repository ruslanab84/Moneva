import SwiftUI
import SwiftData

struct BudgetView: View {
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Environment(\.modelContext) private var context
    @Query private var budgets: [Budget]
    @Query private var members: [FamilyMember]
    @Query private var settlements: [Settlement]
    @State private var isEditing = false
    @AppStorage(Budgeting.rolloverKey(.personal)) private var rolloverPersonal = true
    @AppStorage(Budgeting.rolloverKey(.shared)) private var rolloverShared = true

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
    private var rolloverOn: Bool { scope == .personal ? rolloverPersonal : rolloverShared }
    private var range: Range<Date> { Budgeting.monthRange(for: .now) }
    private var budget: Budget? { budgets.first { $0.scope == scope && ($0.currency ?? currencyCode) == currencyCode && $0.monthStart == range.lowerBound } }
    private var monthTransactions: [Transaction] {
        transactions.filter { $0.scope == scope && $0.currency == currencyCode && range.contains($0.date) }
    }
    private var spent: Decimal { Budgeting.spent(monthTransactions, in: range, scope: scope) }
    private var daysRemaining: Int { Budgeting.daysRemaining(in: range) }

    private var meID: String { FamilySyncEngine.shared.meID }
    private var familyIDs: [String] { FamilyMembers.ids(members: members, transactions: transactions, meID: meID) }
    /// The family cards only mean something once there is somebody else on the
    /// share — one person splitting a budget with themselves is noise.
    private var isFamily: Bool { scope == .shared && familyIDs.count > 1 }
    private func family(_ budget: Budget) -> FamilyBudget { FamilyBudget.decode(budget.familyJSON) }

    var body: some View {
        ScreenScroll(title: range.lowerBound.formatted(.dateTime.month(.wide)), eyebrow: Text("Budget")) {
            ScopePicker(scope: Binding(get: { scope }, set: { scopeRaw = $0.rawValue }))

            if let budget {
                totalCard(budget)
                if isFamily {
                    contributionsCard(budget)
                    balanceCard(budget)
                }
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
        let state = Budgeting.LimitState(progress: progress, daysRemaining: daysRemaining)
        let remaining = max(budget.total - spent, 0)

        VStack(alignment: .leading, spacing: 13) {
            Text("\(remaining.money(currencyCode)) left")
                .font(.money(.largeTitle))
                .foregroundStyle(Palette.ink)
            ProgressBar(progress: progress, tint: color(state), height: 10, accessibilityLabel: "Budget used")
            HStack {
                Text("\(spent.money(currencyCode)) spent of \(budget.total.money(currencyCode))")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(color(state))
                    .accessibilityHidden(true) // ProgressBar already speaks this value
            }
            if let projection = Budgeting.projectedMonthTotal(spent: spent, now: .now) {
                Divider().overlay(Palette.line)
                Label("On this pace you finish the month around \(projection.money(currencyCode)).", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted)
            }
        }
        .monevaCard()
    }

    @ViewBuilder
    private func limitRow(_ limit: BudgetLimit) -> some View {
        let rollover = !rolloverOn ? 0 : Budgeting.rolloverAmount(for: limit.category, transactions: transactions, budgets: budgets, monthStart: range.lowerBound, scope: scope, currency: currencyCode)
        let effectiveLimit = limit.amount + rollover
        let used = monthTransactions.filter { $0.kind == .expense }.reduce(Decimal.zero) { $0 + $1.amount(in: limit.category) }
        let progress = Budgeting.progress(spent: used, limit: effectiveLimit)
        let state = Budgeting.LimitState(progress: progress, daysRemaining: daysRemaining)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                CategoryBadge(category: limit.category, size: 30)
                Text(limit.category?.name ?? String(localized: "Uncategorised"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("\(used.money(currencyCode)) / \(effectiveLimit.money(currencyCode))")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(state == .ok ? Palette.inkMuted : color(state))
            }
            ProgressBar(progress: progress, tint: color(state))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(limit.category?.name ?? String(localized: "Uncategorised")), \(used.money(currencyCode)) of \(effectiveLimit.money(currencyCode)), \(Int(progress * 100)) percent")
    }

    /// Who spent what, and how each person sits against their own ceiling.
    @ViewBuilder
    private func contributionsCard(_ budget: Budget) -> some View {
        let split = family(budget)
        let byMember = Budgeting.spentByMember(monthTransactions, in: range, currency: currencyCode, meID: meID)

        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("Who spent what")
            ForEach(familyIDs, id: \.self) { id in
                let used = byMember[id] ?? 0
                let allowance = split.allowanceAmount(for: id)
                let progress = Budgeting.progress(spent: used, limit: allowance ?? budget.total)
                let state = Budgeting.LimitState(progress: progress, daysRemaining: daysRemaining)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        MemberAvatar(name: FamilyMembers.displayName(for: id, in: members))
                        Text(FamilyMembers.displayName(for: id, in: members))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Text(allowance == nil ? used.money(currencyCode) : "\(used.money(currencyCode)) / \(allowance!.money(currencyCode))")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(allowance == nil || state == .ok ? Palette.inkMuted : color(state))
                    }
                    ProgressBar(progress: progress, tint: allowance == nil ? Palette.accent : color(state))
                }
                .accessibilityElement(children: .combine)
            }
            Text("Shared spending is split \(splitSummary(split)).")
                .font(.caption)
                .foregroundStyle(Palette.inkMuted)
        }
        .monevaCard()
    }

    private func splitSummary(_ split: FamilyBudget) -> String {
        familyIDs
            .map { "\(FamilyMembers.displayName(for: $0, in: members)) \(split.percent(for: $0, members: familyIDs))%" }
            .joined(separator: " · ")
    }

    /// The one number the two of them actually argue about.
    @ViewBuilder
    private func balanceCard(_ budget: Budget) -> some View {
        let balances = Budgeting.balances(
            monthTransactions, settlements: settlements, in: range, currency: currencyCode,
            split: family(budget), members: familyIDs, meID: meID
        )
        let plan = Budgeting.settlementPlan(balances, currency: currencyCode)

        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Settling up")
            if plan.isEmpty {
                Label("Everyone is square this month.", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkMuted)
            } else {
                ForEach(plan.indices, id: \.self) { index in
                    let transfer = plan[index]
                    HStack {
                        Text("\(FamilyMembers.displayName(for: transfer.from, in: members)) owes \(FamilyMembers.displayName(for: transfer.to, in: members)) \(transfer.amount.money(currencyCode))")
                            .font(.money(.title3))
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Button("Settle up", systemImage: "arrow.left.arrow.right") {
                            settle(amount: transfer.amount, from: transfer.from, to: transfer.to)
                        }
                        .buttonStyle(.bordered)
                        .tint(Palette.accent)
                    }
                }
            }
        }
        .monevaCard()
    }

    /// Recorded as a `Settlement`, never as a transaction — moving money
    /// between the two of you is not household spending.
    private func settle(amount: Decimal, from debtor: String, to creditor: String) {
        context.insert(Settlement(amount: amount, currency: currencyCode, date: .now, fromMemberID: debtor, toMemberID: creditor))
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
    @Query private var members: [FamilyMember]
    @Query private var transactions: [Transaction]

    /// Display only — the currency itself is chosen in Settings.
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @State private var total: Decimal = 0
    @State private var limits: [PersistentIdentifier: Decimal] = [:]
    @State private var splitPercent: [String: Int] = [:]
    @State private var allowance: [String: Decimal] = [:]
    @AppStorage(Budgeting.rolloverKey(.personal)) private var rolloverPersonal = true
    @AppStorage(Budgeting.rolloverKey(.shared)) private var rolloverShared = true

    private var rolloverOn: Binding<Bool> {
        scope == .personal ? $rolloverPersonal : $rolloverShared
    }

    private var meID: String { FamilySyncEngine.shared.meID }
    private var familyIDs: [String] { FamilyMembers.ids(members: members, transactions: transactions, meID: meID) }
    private var isFamily: Bool { scope == .shared && familyIDs.count > 1 }
    private var splitTotal: Int { familyIDs.reduce(0) { $0 + (splitPercent[$1] ?? 0) } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Monthly total") {
                    AmountField(title: "Total limit", value: $total, currencyCode: currencyCode)
                        .font(.money(.title2))
                }
                Section("Category limits") {
                    ForEach(CategoryLibrary.visible(categories, scope: scope), id: \.persistentModelID) { category in
                        HStack {
                            CategoryBadge(category: category, size: 30)
                            Text(category.name)
                            Spacer()
                            AmountField(title: "None", value: binding(for: category), currencyCode: currencyCode)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                        }
                    }
                }
                Section {
                    Toggle("Carry over unspent budget", isOn: rolloverOn)
                } footer: {
                    Text("Unspent category limit from last month is added to this month's limit. Overspending never reduces it.")
                }
                if isFamily {
                    Section {
                        ForEach(familyIDs, id: \.self) { id in
                            Stepper(value: splitBinding(for: id), in: 0...100, step: 5) {
                                LabeledContent(FamilyMembers.displayName(for: id, in: members)) {
                                    Text("\(splitPercent[id] ?? 0)%")
                                }
                            }
                        }
                    } header: {
                        Text("Split of shared spending")
                    } footer: {
                        Text(splitTotal == 100 ? "Every shared expense is divided in these proportions." : "The shares add up to \(splitTotal)%, not 100%.")
                            .foregroundStyle(splitTotal == 100 ? Palette.inkMuted : Palette.over)
                    }
                    Section {
                        ForEach(familyIDs, id: \.self) { id in
                            HStack {
                                MemberAvatar(name: FamilyMembers.displayName(for: id, in: members))
                                Text(FamilyMembers.displayName(for: id, in: members))
                                Spacer()
                                AmountField(title: "None", value: allowanceBinding(for: id), currencyCode: currencyCode)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 90)
                            }
                        }
                    } header: {
                        Text("Personal limits")
                    } footer: {
                        Text("Each person's own ceiling inside the shared total. Leave blank for no personal limit.")
                    }
                }
            }
            .navigationTitle(budget == nil ? "New budget" : "Edit budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(total <= 0 || (isFamily && splitTotal != 100))
                }
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

    private func splitBinding(for id: String) -> Binding<Int> {
        Binding(get: { splitPercent[id] ?? 0 }, set: { splitPercent[id] = $0 })
    }

    private func allowanceBinding(for id: String) -> Binding<Decimal> {
        Binding(get: { allowance[id] ?? 0 }, set: { allowance[id] = $0 })
    }

    private func load() {
        // An unset split still has to show as real numbers in the steppers, so
        // the even-split default is resolved once, here.
        let family = FamilyBudget.decode(budget?.familyJSON)
        for id in familyIDs {
            splitPercent[id] = family.percent(for: id, members: familyIDs)
            allowance[id] = family.allowanceAmount(for: id) ?? 0
        }
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
        if isFamily {
            var family = FamilyBudget()
            family.splitPercent = splitPercent.filter { familyIDs.contains($0.key) }
            family.allowance = allowance
                .filter { familyIDs.contains($0.key) && $0.value > 0 }
                .mapValues { NSDecimalNumber(decimal: $0).stringValue }
            target.familyJSON = family.encoded()
        }

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

/// Initials in a circle — enough to tell two people apart in a list without
/// asking anyone for a photo.
struct MemberAvatar: View {
    let name: String

    var body: some View {
        Text(FamilyMembers.initials(name))
            .font(.caption.weight(.bold))
            .foregroundStyle(Palette.accent)
            .frame(width: 30, height: 30)
            .background(Palette.accent.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}
