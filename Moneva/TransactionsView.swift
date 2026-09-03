import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

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

    var body: some View {
        ScreenScroll(title: "Transactions", eyebrow: range.lowerBound.formatted(.dateTime.month(.wide).year())) {
            ScopePicker(scope: Binding(get: { scope }, set: { scopeRaw = $0.rawValue }))

            HStack(spacing: 18) {
                totals("Money in", Budgeting.earned(monthTransactions, in: range, scope: scope), Palette.accent)
                Divider().frame(height: 40).overlay(Palette.line)
                totals("Money out", Budgeting.spent(monthTransactions, in: range, scope: scope), Palette.ink)
            }
            .monevaCard(padding: 16)

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
                    Text(dayTotal(group.items).money())
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.inkMuted)
                }
                .padding(.top, 4)

                VStack(spacing: 0) {
                    ForEach(Array(group.items.enumerated()), id: \.element.persistentModelID) { index, transaction in
                        if index > 0 { Divider().overlay(Palette.line) }
                        TransactionRow(transaction: transaction)
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
    }

    private func totals(_ title: String, _ value: Decimal, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(title)
            Text(value.money())
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
        items.reduce(Decimal.zero) { $0 + ($1.kind == .expense ? $1.amount : 0) }
    }
}
