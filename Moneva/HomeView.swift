import SwiftUI
import SwiftData

struct HomeView: View {
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    // ponytail: fetch-all then filter in memory. Fine for a personal ledger;
    // move to a predicate #Query if a month ever holds thousands of rows.
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var budgets: [Budget]
    @Query private var subscriptions: [Subscription]
    @State private var isSettingsOpen = false

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
    private var range: Range<Date> { Budgeting.monthRange(for: .now) }
    private var spent: Decimal { Budgeting.spent(transactions, in: range, scope: scope) }
    private var budget: Budget? {
        budgets.first { $0.scope == scope && ($0.currency ?? currencyCode) == currencyCode && $0.monthStart == range.lowerBound }
    }
    private var today: [Transaction] {
        transactions.filter { $0.scope == scope && Calendar.current.isDateInToday($0.date) }
    }

    var body: some View {
        ScreenScroll(title: greeting, eyebrow: Text(range.lowerBound.formatted(.dateTime.month(.wide).year()))) {
            ScopePicker(scope: Binding(get: { scope }, set: { scopeRaw = $0.rawValue }))

            if let budget {
                budgetCard(budget)
            } else {
                EmptyHint(
                    title: "No budget for this month",
                    message: "Set a monthly limit and Moneva will track what is left of it.",
                    symbol: "chart.pie"
                )
            }

            AccountsCard()

            HomeAskCard(scope: scope)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                let forecast = Budgeting.forecast(transactions, subscriptions: subscriptions, scope: scope, currency: currencyCode, now: context.date)
                let insightInput = InsightInput.snapshot(transactions, budget: budget, scope: scope, currency: currencyCode, now: context.date)

                HStack(alignment: .top, spacing: 12) {
                    NavigationLink {
                        ScreenScroll(title: "Financial forecast", eyebrow: Text(forecast.currency)) {
                            FinancialForecastView(forecast: forecast)
                        }
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        FinancialForecastPreview(forecast: forecast)
                    }

                    NavigationLink {
                        ScreenScroll(title: "Smart insights", eyebrow: Text(insightInput.currency)) {
                            SmartInsightsView(input: insightInput)
                        }
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        SmartInsightsPreview(input: insightInput)
                    }
                }
                .buttonStyle(.plain)

                MoneyTipCard(date: context.date)
            }

            HStack {
                Eyebrow("Today · \(currencyCode)")
                Spacer()
                Text(todayTotal.money(currencyCode))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.inkMuted)
            }
            .padding(.top, 4)

            if today.isEmpty {
                EmptyHint(
                    title: "Nothing today",
                    message: "Tap the plus button to add an expense or income.",
                    symbol: "tray"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(today.enumerated()), id: \.element.persistentModelID) { index, transaction in
                        if index > 0 { Divider().overlay(Palette.line) }
                        TransactionRow(transaction: transaction)
                    }
                }
                .monevaCard(padding: 16)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { isSettingsOpen = true } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .frame(width: 40, height: 40)
                    .background(Palette.card, in: .circle)
            }
            .accessibilityLabel("Settings")
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
        .sheet(isPresented: $isSettingsOpen) { SettingsView() }
    }

    private var greeting: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: .now) {
        case ..<5, 22...: "Good night"
        case ..<12: "Good morning"
        case ..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var todayTotal: Decimal {
        today.filter { $0.kind == .expense && $0.currency == currencyCode }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    @ViewBuilder
    private func budgetCard(_ budget: Budget) -> some View {
        let progress = Budgeting.progress(spent: spent, limit: budget.total)
        let state = Budgeting.LimitState(progress: progress)
        let remaining = max(budget.total - spent, 0)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow("Spent this month")
                Spacer()
                Text("\(Int(progress * 100))% used")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Palette.line.opacity(0.6), in: .capsule)
                    .foregroundStyle(Palette.inkMuted)
                    .accessibilityHidden(true) // ProgressBar already speaks this value
            }

            Text(spent.money(currencyCode))
                .font(.money(.largeTitle))
                .foregroundStyle(Palette.ink)

            ProgressBar(progress: progress, tint: tint(for: state), accessibilityLabel: "Budget used")

            HStack {
                Text("\(remaining.money(currencyCode)) left of \(budget.total.money(currencyCode))")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
                Spacer()
                Text(stateText(state))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint(for: state))
            }
        }
        .monevaCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spent \(spent.money(currencyCode)) of \(budget.total.money(currencyCode)), \(Int(progress * 100)) percent, \(stateText(state))")
    }

    private func tint(for state: Budgeting.LimitState) -> Color {
        switch state {
        case .ok: Palette.accent
        case .nearingLimit: Palette.warning
        case .atLimit: Palette.over
        }
    }

    private func stateText(_ state: Budgeting.LimitState) -> String {
        switch state {
        case .ok: "On track"
        case .nearingLimit: "Nearing the limit"
        case .atLimit: "Limit reached"
        }
    }
}
