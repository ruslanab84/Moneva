import SwiftUI
import SwiftData

struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Query private var accounts: [Account]
    @Query private var transactions: [Transaction]
    @Query private var transfers: [Transfer]
    @State private var editing: Account?
    @State private var isAdding = false
    @State private var isMoving = false

    private var visible: [Account] { Accounts.visible(accounts) }
    private var archived: [Account] { accounts.filter(\.isArchived) }

    var body: some View {
        ScreenScroll(title: "Accounts", eyebrow: Text("Balances")) {
            if visible.isEmpty {
                EmptyHint(
                    title: "No accounts yet",
                    message: "An account is where the money sits — cash, a card, a bank. Balances never mix currencies.",
                    symbol: "wallet.bifold"
                )
            }

            ForEach(visible, id: \.persistentModelID) { account in
                card(account)
            }

            HStack(spacing: 10) {
                Button("New account", systemImage: "plus") { isAdding = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                if canMove {
                    Button("Transfer", systemImage: "arrow.left.arrow.right") { isMoving = true }
                        .buttonStyle(.bordered)
                        .tint(Palette.accent)
                }
            }

            if !recentTransfers.isEmpty {
                Eyebrow("Recent transfers")
                VStack(spacing: 0) {
                    ForEach(Array(recentTransfers.enumerated()), id: \.element.persistentModelID) { index, transfer in
                        if index > 0 { Divider().overlay(Palette.line) }
                        transferRow(transfer)
                    }
                }
                .monevaCard(padding: 0)
            }

            if !archived.isEmpty {
                Eyebrow("Archived")
                ForEach(archived, id: \.persistentModelID) { account in
                    HStack {
                        Text(account.name).foregroundStyle(Palette.inkMuted)
                        Spacer()
                        Button("Restore") { account.isArchived = false }
                            .font(.footnote.weight(.semibold))
                            .tint(Palette.accent)
                    }
                    .monevaCard()
                }
            }
        }
        .sheet(isPresented: $isAdding) { AccountEditor(account: nil) }
        .sheet(item: $editing) { AccountEditor(account: $0) }
        .sheet(isPresented: $isMoving) { TransferEditor() }
    }

    /// A transfer needs two live accounts sharing one currency — there is no conversion.
    private var canMove: Bool {
        Dictionary(grouping: visible, by: \.currency).values.contains { $0.count > 1 }
    }

    private var recentTransfers: [Transfer] { Accounts.recent(transfers) }

    @ViewBuilder
    private func card(_ account: Account) -> some View {
        let balance = Accounts.balance(account, transactions: transactions, transfers: transfers)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: account.symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(account.tint)
                    .frame(width: 44, height: 44)
                    .background(account.tint.opacity(0.16), in: .rect(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).font(.headline).foregroundStyle(Palette.ink)
                    Text("\(account.kind.title) · \(account.currency)")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkMuted)
                }
                Spacer()
            }
            Text(balance.money(account.currency))
                .font(.money(.title))
                .foregroundStyle(balance < 0 ? Palette.over : Palette.ink)
        }
        .monevaCard()
        .contentShape(Rectangle())
        .onTapGesture { editing = account }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editing = account }
            Button("Archive", systemImage: "archivebox") { account.isArchived = true }
            Button("Delete account", systemImage: "trash", role: .destructive) { context.delete(account) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.name), \(balance.money(account.currency))")
    }

    @ViewBuilder
    private func transferRow(_ transfer: Transfer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(transfer.from?.name ?? String(localized: "Deleted account")) → \(transfer.to?.name ?? String(localized: "Deleted account"))")
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink)
                Text(transfer.date.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.caption)
                    .foregroundStyle(Palette.inkMuted)
            }
            Spacer()
            Text(transfer.amount.money(transfer.currency))
                .font(.money(.subheadline))
                .foregroundStyle(Palette.ink)
        }
        .padding(14)
        .contextMenu {
            Button("Delete transfer", systemImage: "trash", role: .destructive) { context.delete(transfer) }
        }
    }
}

/// One card of balances on the Home screen, tapping through to the full list.
struct AccountsCard: View {
    @Query private var accounts: [Account]
    @Query private var transactions: [Transaction]
    @Query private var transfers: [Transfer]

    private var visible: [Account] { Accounts.visible(accounts) }

    var body: some View {
        NavigationLink {
            AccountsView().navigationBarTitleDisplayMode(.inline)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Eyebrow("Accounts")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.inkFaint)
                        .flipsForRightToLeftLayoutDirection(true)
                }
                if visible.isEmpty {
                    Text("Add cash, a card or a bank account to see what is left on each.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkMuted)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(visible, id: \.persistentModelID) { account in
                                balance(account)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .monevaCard()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func balance(_ account: Account) -> some View {
        let total = Accounts.balance(account, transactions: transactions, transfers: transfers)
        VStack(alignment: .leading, spacing: 4) {
            Label(account.name, systemImage: account.symbol)
                .font(.caption)
                .foregroundStyle(Palette.inkMuted)
                .lineLimit(1)
            Text(total.money(account.currency))
                .font(.money(.title3))
                .foregroundStyle(total < 0 ? Palette.over : Palette.ink)
        }
        .padding(12)
        .background(account.tint.opacity(0.12), in: .rect(cornerRadius: 14))
    }
}

struct AccountEditor: View {
    let account: Account?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]

    @State private var name = ""
    @State private var kind = AccountKind.cash
    @State private var currency = Money.code
    @State private var opening: Decimal = 0
    @State private var tintHex = "78746A"
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(AccountKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    Picker("Currency", selection: $currency) {
                        ForEach(Money.pickerCodes, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(account != nil)
                    AmountField(title: "Starting balance", value: $opening, currencyCode: currency)
                }
                .listRowBackground(Palette.card)
                Section("Colour") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(CategoryLibrary.palette, id: \.tint) { pair in
                            Button { tintHex = pair.tint } label: {
                                Circle()
                                    .fill(Color(hex: pair.tint))
                                    .frame(width: 32, height: 32)
                                    .overlay(Circle().strokeBorder(Palette.ink, lineWidth: tintHex == pair.tint ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(pair.tint)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Palette.card)
                if account != nil {
                    Section {
                        Text("A saved account keeps its currency: its balance is made of transactions already recorded in it, and the app never converts money.")
                            .font(.caption)
                            .foregroundStyle(Palette.inkMuted)
                    }
                    .listRowBackground(Palette.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .tint(Palette.accent)
            .navigationTitle(account == nil ? "New account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded, let account else { loaded = true; return }
        name = account.name
        kind = account.kind
        currency = account.currency
        opening = account.openingBalance
        tintHex = account.tintHex
        loaded = true
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let account {
            account.name = trimmed
            account.kind = kind
            account.openingBalance = opening
            account.tintHex = tintHex
        } else {
            context.insert(Account(name: trimmed, kind: kind, tintHex: tintHex, currency: currency,
                                   openingBalance: opening, sortIndex: Accounts.nextSortIndex(accounts)))
        }
        dismiss()
    }
}

struct TransferEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]

    @State private var source: Account?
    @State private var target: Account?
    @State private var amount: Decimal = 0
    @State private var date = Date.now
    @State private var note = ""

    private var visible: [Account] { Accounts.visible(accounts) }
    /// Only accounts in the source's currency can receive it.
    private var targets: [Account] { visible.filter { $0 !== source && $0.currency == source?.currency } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Move money") {
                    Picker("From", selection: $source) {
                        Text("Choose").tag(Account?.none)
                        ForEach(visible, id: \.persistentModelID) { Text("\($0.name) · \($0.currency)").tag(Account?.some($0)) }
                    }
                    Picker("To", selection: $target) {
                        Text("Choose").tag(Account?.none)
                        ForEach(targets, id: \.persistentModelID) { Text($0.name).tag(Account?.some($0)) }
                    }
                    AmountField(title: "Amount", value: $amount, currencyCode: source?.currency ?? Money.code)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Note", text: $note)
                }
                .listRowBackground(Palette.card)
                Section {
                    Text("A transfer moves your own money. It is not income or spending, so no budget, total or chart counts it.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkMuted)
                }
                .listRowBackground(Palette.card)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .tint(Palette.accent)
            .navigationTitle("Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: source) { _, _ in
                if !targets.contains(where: { $0 === target }) { target = nil }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!Accounts.canTransfer(from: source, to: target, amount: amount))
                }
            }
        }
    }

    private func save() {
        guard let source, let target, Accounts.canTransfer(from: source, to: target, amount: amount) else { return }
        context.insert(Transfer(amount: amount, currency: source.currency, date: date, note: note, from: source, to: target))
        dismiss()
    }
}
