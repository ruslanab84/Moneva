import SwiftUI
import SwiftData
import Charts

private enum TransactionsMode: String, CaseIterable, Identifiable {
    case daily = "Daily", calendar = "Calendar", monthly = "Monthly"
    var id: String { rawValue }
}

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("scope") private var scopeRaw = Scope.personal.rawValue
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \SpendingCategory.name) private var allCategories: [SpendingCategory]

    @State private var assistantOpen = false
    @State private var selectedTransaction: Transaction?
    @State private var mode: TransactionsMode = .daily
    @State private var selectedDate: Date = .now
    @State private var selectedMonth: Date = .now
    @State private var today: Date = .now

    private var scope: Scope { Scope(rawValue: scopeRaw) ?? .personal }
    private var range: Range<Date> { Budgeting.recentRange(days: 62) }
    private var monthTransactions: [Transaction] {
        transactions.filter { $0.scope == scope && range.contains($0.date) }
    }
    private var currentMonthRange: Range<Date> { Budgeting.monthRange(for: today) }
    private var currentMonthTransactions: [Transaction] {
        transactions.filter { $0.scope == scope && currentMonthRange.contains($0.date) }
    }
    private var days: [(day: Date, items: [Transaction])] {
        groupByDay(monthTransactions)
    }
    private var selectedMonthRange: Range<Date> { Budgeting.monthRange(for: selectedMonth) }
    private var selectedMonthTransactions: [Transaction] {
        transactions.filter { $0.scope == scope && selectedMonthRange.contains($0.date) }
    }
    private var selectedMonthDays: [(day: Date, items: [Transaction])] {
        groupByDay(selectedMonthTransactions)
    }
    private func groupByDay(_ items: [Transaction]) -> [(day: Date, items: [Transaction])] {
        Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }
    private var calendarDayTransactions: [Transaction] {
        transactions
            .filter { $0.scope == scope && Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
            .sorted { $0.date > $1.date }
    }
    private var categorySpending: [(category: SpendingCategory, total: Decimal)] {
        let items = mode == .monthly ? selectedMonthTransactions : currentMonthTransactions
        let chartRange = mode == .monthly ? selectedMonthRange : currentMonthRange
        return Budgeting.spendingByCategory(items, categories: CategoryLibrary.visible(allCategories, scope: scope), in: chartRange, scope: scope, currency: currencyCode)
    }

    var body: some View {
        ScreenScroll(title: "Transactions", eyebrow: Text("Last 62 days")) {
            ScopePicker(scope: Binding(get: { scope }, set: { scopeRaw = $0.rawValue }))

            if OnDeviceAI.isSupported {
                Button("Search & explain spending", systemImage: "sparkles") { assistantOpen = true }
                    .proGated()
            }
            Text("Totals in \(currencyCode); other currencies stay separate.").font(.caption).foregroundStyle(Palette.inkMuted)

            if mode != .monthly {
                HStack(spacing: 18) {
                    totals("Money in", Budgeting.earned(currentMonthTransactions, in: currentMonthRange, scope: scope), Palette.accent)
                    Divider().frame(height: 40).overlay(Palette.line)
                    totals("Money out", Budgeting.spent(currentMonthTransactions, in: currentMonthRange, scope: scope), Palette.ink)
                }
                .monevaCard(padding: 16)
            }

            Picker("View", selection: $mode) {
                ForEach(TransactionsMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if !categorySpending.isEmpty {
                CategorySpendingChart(data: categorySpending, currencyCode: currencyCode)
            }

            switch mode {
            case .daily: dailySection
            case .calendar: calendarSection
            case .monthly: monthlySection
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in today = .now }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in today = .now }
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

    private func changeSelectedMonth(by delta: Int) {
        if let newMonth = Calendar.current.date(byAdding: .month, value: delta, to: selectedMonth) {
            selectedMonth = newMonth
        }
    }

    private func dayExpense(_ items: [Transaction]) -> Decimal {
        items.reduce(Decimal.zero) { $0 + ($1.kind == .expense && $1.currency == currencyCode ? $1.amount : 0) }
    }

    private func dayIncome(_ items: [Transaction]) -> Decimal {
        items.reduce(Decimal.zero) { $0 + ($1.kind == .income && $1.currency == currencyCode ? $1.amount : 0) }
    }

    @ViewBuilder private var dailySection: some View {
        if days.isEmpty {
            EmptyHint(
                title: "No transactions yet",
                message: "Everything you add in the last 62 days shows up here, newest first.",
                symbol: "list.bullet"
            )
        }

        ForEach(days, id: \.day) { group in
            HStack {
                Eyebrow(dayTitle(group.day))
                Spacer()
                Text(dayExpense(group.items).money(currencyCode))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.inkMuted)
            }
            .padding(.top, 4)

            transactionList(group.items)
        }
    }

    @ViewBuilder private var calendarSection: some View {
        DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
            .datePickerStyle(.graphical)
            .tint(Palette.accent)
            .monevaCard(padding: 8)

        HStack(spacing: 18) {
            totals("Money in", dayIncome(calendarDayTransactions), Palette.accent)
            Divider().frame(height: 40).overlay(Palette.line)
            totals("Money out", dayExpense(calendarDayTransactions), Palette.ink)
        }
        .monevaCard(padding: 16)

        if calendarDayTransactions.isEmpty {
            EmptyHint(
                title: "No transactions",
                message: "Nothing recorded on this day.",
                symbol: "calendar"
            )
        } else {
            transactionList(calendarDayTransactions)
        }
    }

    @ViewBuilder private var monthlySection: some View {
        HStack {
            Button("", systemImage: "chevron.left") { changeSelectedMonth(by: -1) }
            Spacer()
            Text(selectedMonth.formatted(.dateTime.month(.wide).year())).font(.headline)
            Spacer()
            Button("", systemImage: "chevron.right") { changeSelectedMonth(by: 1) }
        }

        HStack(spacing: 18) {
            totals("Money in", Budgeting.earned(selectedMonthTransactions, in: selectedMonthRange, scope: scope), Palette.accent)
            Divider().frame(height: 40).overlay(Palette.line)
            totals("Money out", Budgeting.spent(selectedMonthTransactions, in: selectedMonthRange, scope: scope), Palette.ink)
        }
        .monevaCard(padding: 16)

        if selectedMonthDays.isEmpty {
            EmptyHint(
                title: "No transactions",
                message: "Nothing recorded this month.",
                symbol: "calendar"
            )
        }
    }

    private func transactionList(_ items: [Transaction]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.persistentModelID) { index, transaction in
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
