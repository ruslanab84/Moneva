import SwiftUI
import SwiftData
import Charts

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

    @State private var assistantOpen = false
    @State private var selectedTransaction: Transaction?

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
    private var range: Range<Date> { Budgeting.monthRange(for: .now) }
    private var monthTransactions: [Transaction] {
        transactions.filter { $0.scope == scope && range.contains($0.date) }
    }
    private var days: [(day: Date, items: [Transaction])] {
        Dictionary(grouping: monthTransactions) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }
    private var trend: [(day: Int, total: Decimal)] {
        Budgeting.cumulativeSpending(monthTransactions, in: range, scope: scope, currency: currencyCode)
    }
    private var todayDay: Int { Calendar.current.component(.day, from: .now) }

    var body: some View {
        ScreenScroll(title: "Transactions", eyebrow: range.lowerBound.formatted(.dateTime.month(.wide).year())) {
            ScopePicker(scope: Binding(get: { scope }, set: { scopeRaw = $0.rawValue }))

            Button("Search & explain spending", systemImage: "sparkles") { assistantOpen = true }
            Text("Totals in \(currencyCode); other currencies stay separate.").font(.caption).foregroundStyle(Palette.inkMuted)

            HStack(spacing: 18) {
                totals("Money in", Budgeting.earned(monthTransactions, in: range, scope: scope), Palette.accent)
                Divider().frame(height: 40).overlay(Palette.line)
                totals("Money out", Budgeting.spent(monthTransactions, in: range, scope: scope), Palette.ink)
            }
            .monevaCard(padding: 16)

            if (trend.last?.total ?? 0) > 0 {
                SpendingTrendChart(trend: trend, todayDay: todayDay, currencyCode: currencyCode)
            }

            if days.isEmpty {
                EmptyHint(
                    title: "No transactions yet",
                    message: "Everything you add this month shows up here, newest first.",
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
                TransactionDetailView(transaction: tx)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedTransaction = nil } } }
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

/// Running total of the month's spending — solid through today, a flat dashed
/// line out to the end of the month so the card doesn't redraw its width daily.
private struct SpendingTrendChart: View {
    let trend: [(day: Int, total: Decimal)]
    let todayDay: Int
    let currencyCode: String

    private var soFar: [(day: Int, total: Decimal)] { trend.filter { $0.day <= todayDay } }
    private var rest: [(day: Int, total: Decimal)] {
        guard let last = soFar.last, let lastDay = trend.last, lastDay.day > last.day else { return [] }
        return [last, (day: lastDay.day, total: last.total)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("Spending this month")

            Chart {
                ForEach(soFar, id: \.day) { point in
                    AreaMark(x: .value("Day", point.day), y: .value("Total", point.total))
                        .foregroundStyle(Palette.ink.opacity(0.08))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", point.day), y: .value("Total", point.total))
                        .foregroundStyle(Palette.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                ForEach(rest, id: \.day) { point in
                    LineMark(x: .value("Day", point.day), y: .value("Total", point.total))
                        .foregroundStyle(Palette.line)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 5]))
                }
                if let last = soFar.last {
                    PointMark(x: .value("Day", last.day), y: .value("Total", last.total))
                        .foregroundStyle(Palette.ink)
                        .symbolSize(56)
                        .annotation(position: .trailing, spacing: 6) {
                            Text(last.total.money(currencyCode))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.ink)
                        }
                }
            }
            .frame(height: 96)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: 7)) { _ in
                    AxisGridLine().foregroundStyle(Palette.line)
                    AxisValueLabel().font(.caption2).foregroundStyle(Palette.inkFaint)
                }
            }
        }
        .monevaCard(padding: 16)
    }
}
