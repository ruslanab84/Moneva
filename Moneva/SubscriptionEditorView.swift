import SwiftUI
import SwiftData

/// New or existing recurring payment. Edits only ever touch what happens next —
/// charges already on file are history and stay put.
struct SubscriptionEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Money.storageKey) private var appCurrency = Money.code
    @Query private var categories: [SpendingCategory]
    @Query private var accounts: [Account]

    private let existing: Subscription?
    private let draftID: UUID?
    private let clarification: String
    private let onSaved: (() -> Void)?
    @State private var reviewed = false
    @State private var saveError: String?
    @State private var saved = false

    @State private var name: String
    @State private var amount: Decimal
    @State private var currency: String
    @State private var kind: TransactionKind
    @State private var category: SpendingCategory?
    @State private var nextPaymentDate: Date
    /// A loan or any fixed-term plan stops on a date. Held as a flag plus a
    /// date so turning it off does not lose what was typed.
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    /// Trial only ever applies at creation — it fixes the anchor day, so an
    /// already-saved subscription has no way to edit it back in.
    @State private var hasTrial: Bool
    @State private var trialEndsAt: Date
    /// 0 means no reminder. An optional Picker selection has to carry nil tags,
    /// and SwiftUI mis-reads those across a Form.
    @State private var reminderDays: Int
    @State private var paymentMode: PaymentMode
    @State private var note: String
    @State private var scope: Scope
    /// Which account the charge leaves from. Optional: a subscription paid in
    /// cash, or one whose account was deleted, still bills normally.
    @State private var account: Account?
    @State private var isPickingCategory = false
    @State private var showDeleteConfirm = false

    private static let reminderOptions = [0, 1, 3, 7]

    init(editing subscription: Subscription? = nil, scope: Scope = .personal, draft: DetectedSubscription? = nil, categories: [SpendingCategory] = [], onSaved: (() -> Void)? = nil) {
        existing = subscription
        draftID = draft?.id
        clarification = draft?.reason ?? ""
        self.onSaved = onSaved
        _name = State(initialValue: subscription?.name ?? draft?.name ?? "")
        _amount = State(initialValue: subscription?.amount ?? draft?.amount ?? 0)
        _currency = State(initialValue: subscription?.currency ?? draft?.currency ?? Money.code)
        _kind = State(initialValue: subscription?.kind ?? .expense)
        _category = State(initialValue: subscription?.category ?? draft?.category)
        let first = subscription?.nextPaymentDate ?? draft?.nextPaymentDate ?? .now
        _nextPaymentDate = State(initialValue: first)
        _hasEndDate = State(initialValue: subscription?.endDate != nil)
        _endDate = State(initialValue: subscription?.endDate ?? Calendar.current.date(byAdding: .month, value: 11, to: first) ?? first)
        _hasTrial = State(initialValue: subscription?.trialEndsAt != nil)
        _trialEndsAt = State(initialValue: subscription?.trialEndsAt ?? Calendar.current.date(byAdding: .day, value: 7, to: first) ?? first)
        _reminderDays = State(initialValue: subscription?.reminderDays ?? 0)
        _account = State(initialValue: subscription?.account)
        _paymentMode = State(initialValue: subscription?.paymentMode ?? .ask)
        _note = State(initialValue: subscription?.note ?? "")
        _scope = State(initialValue: subscription?.scope ?? draft?.scope ?? scope)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !saved && !trimmedName.isEmpty && Money.valid(amount, currency: currency) && CategoryLibrary.isSelectable(category, scope: scope, kind: kind) && (draftID == nil || reviewed) && Calendar.current.startOfDay(for: nextPaymentDate) >= Calendar.current.startOfDay(for: .now) && (!hasEndDate || Calendar.current.startOfDay(for: endDate) >= Calendar.current.startOfDay(for: nextPaymentDate)) && (!hasTrial || existing != nil || (Calendar.current.startOfDay(for: trialEndsAt) >= Calendar.current.startOfDay(for: nextPaymentDate) && (!hasEndDate || Calendar.current.startOfDay(for: trialEndsAt) <= Calendar.current.startOfDay(for: endDate)))) }

    /// How many charges the chosen term covers, so 24 monthly instalments can
    /// be checked against the date before saving.
    private var plannedPayments: Int? {
        Subscriptions.remainingPayments(nextPaymentDate: nextPaymentDate, anchorDay: Calendar.current.component(.day, from: nextPaymentDate), endDate: hasEndDate ? endDate : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(TransactionKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: kind) { _, newKind in
                        if !CategoryLibrary.isSelectable(category, scope: scope, kind: newKind) { category = nil }
                    }
                    TextField("Service name", text: $name)
                    AmountField(title: "Amount", value: $amount, currencyCode: currency)
                    if let existing, let change = Subscriptions.priceChange(existing), change.currency == currency {
                        SubscriptionPriceChangeBadge(change: change)
                    }
                    if let existing, paymentMode == .ask, Subscriptions.isPotentiallyUnused(existing) {
                        unusedSubscriptionHint
                    }
                }

                Section {
                    Button { isPickingCategory = true } label: {
                        HStack(spacing: 12) {
                            CategoryBadge(category: category, size: 32)
                            Text(category?.name ?? String(localized: "Choose a category"))
                                .foregroundStyle(category == nil ? Palette.inkMuted : Palette.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(Palette.inkFaint)
                                .flipsForRightToLeftLayoutDirection(true)
                        }
                    }
                    // Monthly is the only frequency in this version; the row
                    // still says so rather than leaving the user guessing.
                    LabeledContent("Billing", value: BillingFrequency.monthly.title)
                    DatePicker("Next payment", selection: $nextPaymentDate, displayedComponents: .date)
                    Toggle("Ends on a date", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("Last payment", selection: $endDate, in: nextPaymentDate..., displayedComponents: .date)
                    }
                    if existing == nil {
                        Toggle("Free trial", isOn: $hasTrial)
                        if hasTrial {
                            DatePicker("Trial ends", selection: $trialEndsAt, in: nextPaymentDate..., displayedComponents: .date)
                        }
                    }
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.title).tag($0) }
                    }
                    // Only accounts holding this price's currency: a balance is
                    // never converted, so no other account could pay it.
                    let usable = Accounts.visible(accounts).filter { $0.currency == currency }
                    if !usable.isEmpty {
                        Picker("Account", selection: $account) {
                            Text("None").tag(Account?.none)
                            ForEach(usable, id: \.persistentModelID) { Text($0.name).tag(Account?.some($0)) }
                        }
                        .onChange(of: currency) { _, code in
                            account = Accounts.holder(account, currency: code)
                        }
                    }
                } footer: {
                    if let plannedPayments {
                        Text("\(plannedPayments) payment\(plannedPayments == 1 ? "" : "s") of \(amount.money(currency)) — \((amount * Decimal(plannedPayments)).money(currency)) in total.")
                    } else {
                        Text("No end date: this repeats until you pause or delete it.")
                    }
                }

                Section("On the payment date") {
                    Picker("Payment", selection: $paymentMode) {
                        ForEach(PaymentMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Remind me", selection: $reminderDays) {
                        ForEach(Self.reminderOptions, id: \.self) { option in
                            Text(option == 0 ? "No reminder" : "\(option) day\(option == 1 ? "" : "s") before")
                                .tag(option)
                        }
                    }
                }

                if let saveError { Section { Text(saveError).foregroundStyle(Palette.over) } }
                if draftID != nil {
                    Section("Review draft") {
                        if !clarification.isEmpty { Text(clarification) }
                        Toggle("I checked the monthly schedule and all details", isOn: $reviewed)
                    }
                }
                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical)
                }

                if let existing {
                    Section {
                        Button(existing.status == .active ? "Pause subscription" : "Resume subscription") {
                            togglePause(existing)
                        }
                        Button("Delete subscription", role: .destructive) { showDeleteConfirm = true }
                    } footer: {
                        Text("Deleting stops future charges. Transactions already added stay in your history.")
                    }
                }
            }
            .navigationTitle(existing == nil ? "New subscription" : "Edit subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
            .sheet(isPresented: $isPickingCategory) {
                CategoryPickerView(selection: $category, scope: scope, kind: kind)
            }
            .confirmationDialog("Delete this subscription?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text("Past transactions are kept.")
            }
            .onChange(of: scope) { _, scope in
                if !CategoryLibrary.isSelectable(category, scope: scope, kind: kind) { category = nil }
            }
            .onAppear {
                if existing == nil && draftID == nil { currency = appCurrency }
                if category == nil { category = CategoryLibrary.visible(categories, scope: scope, kind: kind).first }
            }
        }
    }

    private var unusedSubscriptionHint: some View {
        Label("You’ve skipped several payments in a row. Are you still using this subscription? Skipped payments don’t confirm service usage.", systemImage: "info.circle")
            .font(.footnote)
            .foregroundStyle(Palette.inkMuted)
            .padding(10)
            .background(Palette.ground, in: .rect(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    private func save() {
        guard canSave else { return }
        if let draftID {
            do {
                let existingDrafts = try context.fetch(FetchDescriptor<Subscription>())
                if existingDrafts.contains(where: { $0.draftID == draftID.uuidString }) { dismiss(); onSaved?(); return }
            } catch { saveError = error.localizedDescription; return }
        }
        let calendar = Calendar.current
        let subscription: Subscription
        if let existing {
            existing.name = trimmedName
            existing.amount = amount
            existing.currency = currency
            existing.category = category
            existing.kind = kind
            existing.nextPaymentDate = nextPaymentDate
            existing.endDate = hasEndDate ? endDate : nil
            existing.anchorDay = calendar.component(.day, from: nextPaymentDate)
            existing.reminderDays = reminderDays == 0 ? nil : reminderDays
            existing.paymentMode = paymentMode
            existing.note = note
            existing.scope = scope
            existing.account = Accounts.holder(account, currency: currency)
            subscription = existing
        } else {
            let created = Subscription(
                name: trimmedName,
                amount: amount,
                currency: currency,
                nextPaymentDate: nextPaymentDate,
                endDate: hasEndDate ? endDate : nil,
                trialEndsAt: hasTrial ? trialEndsAt : nil,
                reminderDays: reminderDays == 0 ? nil : reminderDays,
                paymentMode: paymentMode,
                note: note,
                scope: scope,
                category: category,
                kind: kind
            )
            created.account = Accounts.holder(account, currency: currency)
            context.insert(created)
            subscription = created
        }
        if let draftID { subscription.draftID = draftID.uuidString }
        do { try context.save() } catch { context.rollback(); saveError = error.localizedDescription; return }
        saved = true
        Task { await Reminders.reschedule(subscription) }
        dismiss()
        onSaved?()
    }

    private func togglePause(_ subscription: Subscription) {
        if subscription.status == .paused {
            subscription.nextPaymentDate = Subscriptions.firstFutureDate(subscription, now: .now)
        }
        subscription.status = subscription.status == .active ? .paused : .active
        do { try context.save() } catch { context.rollback(); saveError = error.localizedDescription; return }
        Task { await Reminders.reschedule(subscription) }
        dismiss()
    }

    private func delete() {
        guard let existing else { return }
        Reminders.cancel(existing)
        // Payments cascade; their transactions are only nullified, so the
        // money that was actually spent stays in the history.
        context.delete(existing)
        do { try context.save(); dismiss() } catch { context.rollback(); saveError = error.localizedDescription }
    }
}
