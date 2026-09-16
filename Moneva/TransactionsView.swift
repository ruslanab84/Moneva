import SwiftUI
import SwiftData
import Charts

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \SpendingCategory.name) private var allCategories: [SpendingCategory]

    @State private var assistantOpen = false
    @State private var selectedTransaction: Transaction?
    @State private var period: TransactionPeriod = .month
    @State private var anchorDate: Date = .now

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
    private var range: Range<Date> { Budgeting.range(for: period, anchor: anchorDate) }
    private var periodTransactions: [Transaction] {
        transactions.filter { $0.scope == scope && range.contains($0.date) }
    }
    private var days: [(day: Date, items: [Transaction])] {
        Dictionary(grouping: periodTransactions) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }
    private var categorySpending: [(category: SpendingCategory, total: Decimal)] {
        Budgeting.spendingByCategory(periodTransactions, categories: CategoryLibrary.visible(allCategories, scope: scope), in: range, scope: scope, currency: currencyCode)
    }
    private var periodTitle: String {
        switch period {
        case .day:
            return range.lowerBound.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).year())
        case .week:
            let end = Calendar.current.date(byAdding: .day, value: -1, to: range.upperBound) ?? range.upperBound
            return "\(range.lowerBound.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month:
            return range.lowerBound.formatted(.dateTime.month(.wide).year())
        }
    }
    private var emptyPeriodDescriptor: String {
        switch period {
        case .day: return "today"
        case .week: return "this week"
        case .month: return "this month"
        }
    }

    var body: some View {
        ScreenScroll(title: "Transactions") {
            ScopePicker(scope: Binding(get: { scope }, set: { scopeRaw = $0.rawValue }))

            Picker("Period", selection: $period) {
                ForEach(TransactionPeriod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: period) { _, _ in anchorDate = .now }

            HStack {
                Button { anchorDate = Budgeting.shift(period, by: -1, from: anchorDate) } label: {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(periodTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Button { anchorDate = Budgeting.shift(period, by: 1, from: anchorDate) } label: {
                    Image(systemName: "chevron.right")
                }
            }
            .foregroundStyle(Palette.inkMuted)

            Button("Search & explain spending", systemImage: "sparkles") { assistantOpen = true }
            Text("Totals in \(currencyCode); other currencies stay separate.").font(.caption).foregroundStyle(Palette.inkMuted)

            HStack(spacing: 18) {
                totals("Money in", Budgeting.earned(periodTransactions, in: range, scope: scope), Palette.accent)
                Divider().frame(height: 40).overlay(Palette.line)
                totals("Money out", Budgeting.spent(periodTransactions, in: range, scope: scope), Palette.ink)
            }
            .monevaCard(padding: 16)

            if !categorySpending.isEmpty {
                CategorySpendingChart(data: categorySpending, currencyCode: currencyCode)
            }

            if days.isEmpty {
                EmptyHint(
                    title: "No transactions yet",
                    message: "Everything you add \(emptyPeriodDescriptor) shows up here, newest first.",
                    symbol: "list.bullet"
                )
            }

            ForEach(days, id: \.day) { group in
                HStack {
                    Eyebrow(dayTitle(group.day))
                    Spacer()
                    Text(dayTotal(group.items).money(currencyCode))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.inkMuted)
                }
                .padding(.top, 4)

                VStack(spacing: 0) {
                    ForEach(Array(group.items.enumerated()), id: \.element.persistentModelID) { index, transaction in
                        if index > 0 { Divider().overlay(Palette.line) }
                        TransactionRow(transaction: transaction)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedTransaction = transaction }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    context.delete(transaction)
                                }
                            }
                    }
                }
                .monevaCard(padding: 16)
            }
        }
        .sheet(isPresented: $assistantOpen) { SpendingAssistantView(scope: scope) }
        .sheet(item: $selectedTransaction) { tx in
            NavigationStack {
                TransactionEditView(transaction: tx)
            }
        }
    }

    private func totals(_ title: String, _ value: Decimal, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(title)
            Text(value.money(currencyCode))
                .font(.money(.title2))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func dayTotal(_ items: [Transaction]) -> Decimal {
        items.reduce(Decimal.zero) { $0 + ($1.kind == .expense && $1.currency == currencyCode ? $1.amount : 0) }
    }
}
