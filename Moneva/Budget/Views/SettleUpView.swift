import SwiftUI
import SwiftData

/// One debt in plain words, from this device's point of view.
private func debtText(from debtor: String, to creditor: String, amount: Decimal, currency: String, members: [FamilyMember], meID: String) -> String {
    let money = amount.money(currency)
    if debtor == meID { return String(localized: "You owe \(FamilyMembers.displayName(for: creditor, in: members)) \(money)") }
    if creditor == meID { return String(localized: "\(FamilyMembers.displayName(for: debtor, in: members)) owes you \(money)") }
    return String(localized: "\(FamilyMembers.displayName(for: debtor, in: members)) owes \(FamilyMembers.displayName(for: creditor, in: members)) \(money)")
}

/// "Who paid" and "how is it split" for one shared expense. Hidden until there
/// is somebody else on the share — nobody splits with themselves.
struct SplitFields: View {
    @Binding var payerID: String
    @Binding var split: FamilyBudget?
    /// Who paid when `payerID` is empty: the author (me for a new expense).
    let author: String
    @Query private var members: [FamilyMember]
    /// Custom stays custom while you step it through 50/50 or 100/0.
    @State private var editingCustom = false

    private var meID: String { FamilySyncEngine.shared.meID }
    private var ids: [String] { FamilyMembers.ids(members: members, transactions: [], meID: meID) }

    var body: some View {
        if ids.count > 1 {
            Picker("Paid by", selection: Binding(
                get: { payerID.isEmpty ? author : payerID },
                set: { payerID = $0 == author ? "" : $0 }
            )) {
                ForEach(ids, id: \.self) { Text(FamilyMembers.displayName(for: $0, in: members)).tag($0) }
            }
            Picker("Split", selection: Binding(get: { choice }, set: choose)) {
                Text("Budget default").tag("budget")
                Text("Equally").tag("even")
                ForEach(ids, id: \.self) { id in
                    Text("Only \(FamilyMembers.displayName(for: id, in: members))").tag("only:" + id)
                }
                Text("Custom").tag("custom")
            }
            if choice == "custom" {
                ForEach(ids, id: \.self) { id in
                    Stepper(value: percentBinding(for: id), in: 0...100, step: 5) {
                        Text("\(FamilyMembers.displayName(for: id, in: members)) \(split?.splitPercent[id] ?? 0)%")
                    }
                }
                let total = split?.splitPercent.values.reduce(0, +) ?? 0
                if total != 100 {
                    Text("The split adds up to \(total)%, not 100%.").font(.caption).foregroundStyle(Palette.over)
                }
            }
        }
    }

    /// The picker's tag for whatever `split` currently holds.
    private var choice: String {
        guard let split else { return "budget" }
        if editingCustom { return "custom" }
        let even = ids.reduce(into: [String: Int]()) { $0[$1] = FamilyBudget().percent(for: $1, members: ids) }
        if split.splitPercent == even { return "even" }
        let owners = split.splitPercent.filter { $0.value > 0 }
        if owners.count == 1, owners.first?.value == 100, let only = owners.first?.key { return "only:" + only }
        return "custom"
    }

    private func choose(_ tag: String) {
        editingCustom = tag == "custom"
        switch tag {
        case "budget": split = nil
        case "even": split = FamilyBudget(splitPercent: ids.reduce(into: [:]) { $0[$1] = FamilyBudget().percent(for: $1, members: ids) })
        case "custom":
            // Start from what is on screen, with every member listed so each gets a stepper.
            let base = split ?? FamilyBudget()
            split = FamilyBudget(splitPercent: ids.reduce(into: [:]) { $0[$1] = base.percent(for: $1, members: ids) })
        default: split = FamilyBudget(splitPercent: [String(tag.dropFirst("only:".count)): 100])
        }
    }

    private func percentBinding(for id: String) -> Binding<Int> {
        Binding(get: { split?.splitPercent[id] ?? 0 }, set: { split?.splitPercent[id] = $0 })
    }
}

/// Home's one-line answer to "who owes whom", in the display currency.
struct SettleUpCard: View {
    let transactions: [Transaction]
    let currencyCode: String
    @Query private var members: [FamilyMember]
    @Query private var settlements: [Settlement]
    @Query private var budgets: [Budget]

    private var meID: String { FamilySyncEngine.shared.meID }
    private var ids: [String] { FamilyMembers.ids(members: members, transactions: transactions, meID: meID) }

    var body: some View {
        if ids.count > 1 {
            let plan = Budgeting.settlementPlan(
                Budgeting.balances(transactions, settlements: settlements, currency: currencyCode, budgets: budgets, members: ids, meID: meID),
                currency: currencyCode
            )
            let others = Budgeting.balanceCurrencies(transactions, settlements: settlements).filter { code in
                code != currencyCode && !Budgeting.settlementPlan(
                    Budgeting.balances(transactions, settlements: settlements, currency: code, budgets: budgets, members: ids, meID: meID),
                    currency: code
                ).isEmpty
            }
            NavigationLink { SettleUpView() } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Settling up")
                        if plan.isEmpty {
                            Text("You're all square").font(.money(.title3)).foregroundStyle(Palette.ink)
                        } else {
                            ForEach(plan.indices, id: \.self) { index in
                                Text(debtText(from: plan[index].from, to: plan[index].to, amount: plan[index].amount, currency: currencyCode, members: members, meID: meID))
                                    .font(.money(.title3))
                                    .foregroundStyle(Palette.ink)
                            }
                        }
                        if !others.isEmpty {
                            Text("Also open in \(others.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(Palette.inkMuted)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.inkFaint)
                        .flipsForRightToLeftLayoutDirection(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .monevaCard()
            }
            .buttonStyle(.plain)
        }
    }
}

/// The running balance per currency, the transfers that clear it, and every
/// settlement so far. Debt never lapses at month end; currencies never mix.
struct SettleUpView: View {
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]
    @Query private var members: [FamilyMember]
    @Query(sort: \Settlement.date, order: .reverse) private var settlements: [Settlement]
    @Query private var budgets: [Budget]
    @State private var settling: Pending?
    @State private var deleting: Settlement?

    struct Pending: Identifiable {
        let id = UUID()
        let from: String
        let to: String
        let owed: Decimal
        let currency: String
    }

    private var meID: String { FamilySyncEngine.shared.meID }
    private var ids: [String] { FamilyMembers.ids(members: members, transactions: transactions, meID: meID) }

    var body: some View {
        ScreenScroll(title: "Settle up", eyebrow: Text("Shared")) {
            let currencies = Budgeting.balanceCurrencies(transactions, settlements: settlements)
            if currencies.isEmpty {
                EmptyHint(title: "Nothing to settle yet", message: "Shared expenses and who paid them will show up here.", symbol: "arrow.left.arrow.right")
            }
            ForEach(currencies, id: \.self) { currency in
                currencySection(currency)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $settling) { pending in
            SettleSheet(pending: pending, title: debtText(from: pending.from, to: pending.to, amount: pending.owed, currency: pending.currency, members: members, meID: meID)) { amount in
                context.insert(Settlement(amount: amount, currency: pending.currency, date: .now, fromMemberID: pending.from, toMemberID: pending.to))
            }
        }
        .confirmationDialog("Delete this settlement?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting { context.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("The amount goes back into the balance.")
        }
    }

    @ViewBuilder
    private func currencySection(_ currency: String) -> some View {
        let plan = Budgeting.settlementPlan(
            Budgeting.balances(transactions, settlements: settlements, currency: currency, budgets: budgets, members: ids, meID: meID),
            currency: currency
        )
        let history = settlements.filter { $0.currency == currency }

        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(currency)
            if plan.isEmpty {
                Label("Everyone is square.", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkMuted)
            }
            ForEach(plan.indices, id: \.self) { index in
                let transfer = plan[index]
                HStack {
                    Text(debtText(from: transfer.from, to: transfer.to, amount: transfer.amount, currency: currency, members: members, meID: meID))
                        .font(.money(.title3))
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Button("Settle up") {
                        settling = Pending(from: transfer.from, to: transfer.to, owed: transfer.amount, currency: currency)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.accent)
                }
            }
            if !history.isEmpty {
                Divider()
                Text("History").font(.footnote.weight(.semibold)).foregroundStyle(Palette.inkMuted)
                ForEach(history, id: \.persistentModelID) { settlement in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(FamilyMembers.displayName(for: settlement.fromMemberID, in: members)) → \(FamilyMembers.displayName(for: settlement.toMemberID, in: members))")
                                .font(.subheadline)
                                .foregroundStyle(Palette.ink)
                            Text(settlement.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(Palette.inkMuted)
                        }
                        Spacer()
                        Text(settlement.amount.money(currency)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                        Button("Delete settlement", systemImage: "trash", role: .destructive) { deleting = settlement }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Palette.over)
                    }
                }
            }
        }
        .monevaCard()
    }
}

/// Confirms one payment, full or partial — never more than is owed.
private struct SettleSheet: View {
    let pending: SettleUpView.Pending
    let title: String
    let onConfirm: (Decimal) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Decimal = 0

    private var valid: Bool { Money.valid(amount, currency: pending.currency) && amount <= pending.owed }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(title: "Amount", value: $amount, currencyCode: pending.currency)
                } header: {
                    Text(title)
                } footer: {
                    Text("Pay less to settle part of it; the rest stays owed.")
                }
            }
            .navigationTitle("Settle up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") { onConfirm(amount); dismiss() }.disabled(!valid)
                }
            }
            .onAppear { amount = pending.owed }
        }
        .presentationDetents([.medium])
    }
}
