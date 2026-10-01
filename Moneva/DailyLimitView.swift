import SwiftUI

/// Per-scope storage keys. `@AppStorage`, not SwiftData: a device-local
/// preference needs no migration and must not ride the shared-budget sync.
enum DailyLimitStore {
    static func modeKey(_ scope: Scope) -> String { "dailyLimitMode.\(scope.rawValue)" }
    static func amountKey(_ scope: Scope) -> String { "dailyLimitAmount.\(scope.rawValue)" }
}

struct DailyLimitCard: View {
    let scope: Scope
    let transactions: [Transaction]
    let subscriptions: [Subscription]
    let budgetTotal: Decimal?
    let currencyCode: String

    @AppStorage private var modeRaw: String
    @AppStorage private var customRaw: String
    @State private var isOpen = false

    init(scope: Scope, transactions: [Transaction], subscriptions: [Subscription], budgetTotal: Decimal?, currencyCode: String) {
        self.scope = scope
        self.transactions = transactions
        self.subscriptions = subscriptions
        self.budgetTotal = budgetTotal
        self.currencyCode = currencyCode
        _modeRaw = AppStorage(wrappedValue: Budgeting.DailyLimitMode.automatic.rawValue, DailyLimitStore.modeKey(scope))
        _customRaw = AppStorage(wrappedValue: "", DailyLimitStore.amountKey(scope))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let forecast = Budgeting.forecast(transactions, subscriptions: subscriptions, scope: scope, currency: currencyCode, now: context.date)
            let automatic = Budgeting.automaticDailyLimit(budgetTotal: budgetTotal, transactions: transactions, forecast: forecast, scope: scope, currency: currencyCode, now: context.date)
            let limit = Budgeting.dailyLimit(mode: Budgeting.DailyLimitMode(rawValue: modeRaw) ?? .automatic, custom: Money.parse(customRaw) ?? 0, automatic: automatic)
            let spentToday = Budgeting.spent(transactions, in: Budgeting.recentRange(days: 1, from: context.date), scope: scope, currency: currencyCode)

            Button { isOpen = true } label: {
                content(limit: limit, spentToday: spentToday)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $isOpen) {
                DailyLimitSheet(scope: scope, currencyCode: currencyCode, automatic: automatic)
            }
        }
    }

    @ViewBuilder
    private func content(limit: Decimal?, spentToday: Decimal) -> some View {
        if let limit {
            let progress = Budgeting.progress(spent: spentToday, limit: limit)
            let tint = tint(Budgeting.LimitState(progress: progress))
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("Daily limit")
                Text(max(limit - spentToday, 0).money(currencyCode))
                    .font(.money(.largeTitle))
                    .foregroundStyle(Palette.ink)
                ProgressBar(progress: progress, tint: tint, accessibilityLabel: "Daily limit used")
                Text("Spent \(spentToday.money(currencyCode)) of \(limit.money(currencyCode)) today")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
            }
            .monevaCard()
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens daily limit settings")
        } else {
            EmptyHint(
                title: "No daily limit",
                message: "Tap to let Moneva calculate one or set your own.",
                symbol: "gauge.with.dots.needle.33percent"
            )
        }
    }

    private func tint(_ state: Budgeting.LimitState) -> Color {
        switch state {
        case .ok: Palette.accent
        case .nearingLimit: Palette.warning
        case .atLimit: Palette.over
        }
    }
}

struct DailyLimitSheet: View {
    let scope: Scope
    let currencyCode: String
    let automatic: Decimal?

    @Environment(\.dismiss) private var dismiss
    @AppStorage private var modeRaw: String
    @AppStorage private var customRaw: String
    // Local copies so Cancel reverts, like BudgetEditor.
    @State private var mode = Budgeting.DailyLimitMode.automatic
    @State private var custom = Decimal.zero

    init(scope: Scope, currencyCode: String, automatic: Decimal?) {
        self.scope = scope
        self.currencyCode = currencyCode
        self.automatic = automatic
        _modeRaw = AppStorage(wrappedValue: Budgeting.DailyLimitMode.automatic.rawValue, DailyLimitStore.modeKey(scope))
        _customRaw = AppStorage(wrappedValue: "", DailyLimitStore.amountKey(scope))
    }

    /// Slider spans 0 to a few times the automatic figure (or a flat default),
    /// and never less than what is typed, so a typed value is never clipped.
    private var sliderMax: Double {
        let base = automatic.map { ($0 * 3).doubleValue } ?? 0
        return max(base, custom.doubleValue, 100).rounded(.up)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Calculation", selection: $mode) {
                        Text("Automatic").tag(Budgeting.DailyLimitMode.automatic)
                        Text("Custom").tag(Budgeting.DailyLimitMode.custom)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Calculation options")
                } footer: {
                    if mode == .automatic {
                        Text("Moneva calculates your daily limit from what is left of this month's budget, divided by the days left. It is set once each day and is not affected by today's transactions. Without a budget it uses your balance and expected income.")
                    } else {
                        Text("While you can set the limit to whatever you want, please stay within reason so you don't overspend.")
                    }
                }

                if mode == .automatic {
                    Section {
                        LabeledContent("Your daily budget") {
                            Text((automatic ?? 0).money(currencyCode))
                                .font(.headline)
                        }
                    }
                } else {
                    Section {
                        AmountField(title: "0.00", value: $custom, currencyCode: currencyCode)
                            .font(.money(.title2))
                        Slider(
                            value: Binding(
                                get: { custom.doubleValue },
                                set: { custom = Budgeting.rounded(Decimal($0), currency: currencyCode) }
                            ),
                            in: 0...sliderMax,
                            step: 1
                        )
                    } footer: {
                        Text("The amount you enter here will be the same every day and will not change based on your remaining balance for the period.")
                    }
                }
            }
            .navigationTitle("Daily limit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") { save() }
                        .labelStyle(.iconOnly)
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        mode = Budgeting.DailyLimitMode(rawValue: modeRaw) ?? .automatic
        custom = Money.parse(customRaw) ?? 0
    }

    private func save() {
        modeRaw = mode.rawValue
        customRaw = AmountField.display(Budgeting.rounded(custom, currency: currencyCode))
        dismiss()
    }
}
