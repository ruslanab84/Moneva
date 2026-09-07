import SwiftUI
import Charts

/// This month's spending broken down by category, with a settings sheet for
/// how to see it — chart kind, per-slice labels, sort, and color source.
/// Swift decides every number here; the view only picks how to draw it.
struct CategorySpendingChart: View {
    let data: [(category: SpendingCategory, total: Decimal)]
    let currencyCode: String

    enum ChartKind: String, CaseIterable, Identifiable {
        case donut = "Donut", pie = "Pie", bar = "Bar", horizontalBar = "Horizontal", stackedBar = "Stacked"
        var id: String { rawValue }
    }
    enum LabelMode: String, CaseIterable, Identifiable {
        case amount = "Amount", percent = "Percent", hidden = "Hidden"
        var id: String { rawValue }
    }
    enum CategorySort: String, CaseIterable, Identifiable {
        case descending = "Highest first", ascending = "Lowest first", alphabetical = "A–Z"
        var id: String { rawValue }
    }
    enum PaletteMode: String, CaseIterable, Identifiable {
        case categoryTint = "Category colors", accentShades = "Accent shades"
        var id: String { rawValue }
    }

    @State private var chartKind: ChartKind = .stackedBar
    @State private var labelMode: LabelMode = .percent
    @State private var sort: CategorySort = .descending
    @State private var paletteMode: PaletteMode = .categoryTint
    @State private var settingsOpen = false
    @State private var selectedID: String?
    // Charts needs a real backing store to read back, not just write to — a
    // proxy Binding whose getter always returns nil never sees a tap land.
    @State private var angleSelection: Double?
    @State private var stackSelection: Double?

    private struct Slice: Identifiable {
        let id: String
        let category: SpendingCategory
        let amount: Decimal
        let value: Double
        let share: Double
        let color: Color
    }

    private var total: Decimal { data.reduce(Decimal.zero) { $0 + $1.total } }

    private var slices: [Slice] {
        let ordered: [(category: SpendingCategory, total: Decimal)]
        switch sort {
        case .descending: ordered = data.sorted { $0.total > $1.total }
        case .ascending: ordered = data.sorted { $0.total < $1.total }
        case .alphabetical: ordered = data.sorted { $0.category.name.localizedCaseInsensitiveCompare($1.category.name) == .orderedAscending }
        }
        let totalValue = total.doubleValue
        let count = ordered.count
        return ordered.enumerated().map { rank, entry in
            let value = entry.total.doubleValue
            return Slice(
                id: entry.category.name,
                category: entry.category,
                amount: entry.total,
                value: value,
                share: totalValue > 0 ? value / totalValue : 0,
                color: color(for: entry.category, rank: rank, count: count)
            )
        }
    }

    /// Synthetic bucket for the bar chart's overflow categories — reuses the
    /// model's own default neutral tint/soft (Models.swift) rather than
    /// inventing a new color.
    private static let othersCategory = SpendingCategory(name: "Others", symbol: "ellipsis.circle", tintHex: "78746A", softHex: "E4E2DB")

    /// The `.bar` chart's x-axis draws one label per bar with no rotation —
    /// past ~6 categories they overlap and become unreadable. Grouped into
    /// top 5 by amount (always descending, independent of `sort`) + "Others"
    /// so the axis stays legible; the legend below still lists every real
    /// category via `slices`.
    private var barSlices: [Slice] {
        guard slices.count > 6 else { return slices }
        let byAmount = slices.sorted { $0.value > $1.value }
        let top = Array(byAmount.prefix(5))
        let rest = byAmount.dropFirst(5)
        let others = Slice(
            id: "__others__",
            category: Self.othersCategory,
            amount: rest.reduce(Decimal.zero) { $0 + $1.amount },
            value: rest.reduce(0.0) { $0 + $1.value },
            share: rest.reduce(0.0) { $0 + $1.share },
            color: Palette.inkFaint
        )
        return top + [others]
    }

    private func color(for category: SpendingCategory, rank: Int, count: Int) -> Color {
        switch paletteMode {
        case .categoryTint: category.tint
        case .accentShades: Palette.accent.opacity(count <= 1 ? 1 : 1 - (Double(rank) / Double(count - 1)) * 0.65)
        }
    }

    /// Finds the slice a tapped position along the plotted amount axis falls
    /// into — the angle (donut/pie) and the stacked-bar's x axis both plot in
    /// the same "amount" units, so one cumulative-sum walk serves both.
    private func slice(atCumulative value: Double) -> Slice? {
        var running = 0.0
        for slice in slices {
            running += slice.value
            if value <= running { return slice }
        }
        return slices.last
    }

    private func label(for slice: Slice) -> String? {
        switch labelMode {
        case .hidden: nil
        case .amount: slice.amount.money(currencyCode)
        case .percent: slice.share.formatted(.percent.precision(.fractionLength(1)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow("Spending by category")
                Spacer()
                Text(total.money(currencyCode)).font(.money(.title3))
                Button {
                    settingsOpen = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Palette.inkFaint)
                }
            }

            chart
                .frame(height: chartKind == .stackedBar ? 36 : chartKind == .bar || chartKind == .horizontalBar ? 160 : 190)
                .animation(.snappy(duration: 0.35), value: chartKind)
                .animation(.snappy(duration: 0.35), value: sort)
                .animation(.snappy(duration: 0.35), value: paletteMode)

            VStack(spacing: 10) {
                ForEach(slices) { slice in
                    legendRow(slice)
                        .onTapGesture { selectedID = selectedID == slice.id ? nil : slice.id }
                }
            }
            .animation(.snappy(duration: 0.35), value: sort)
        }
        .monevaCard(padding: 16)
        .sheet(isPresented: $settingsOpen) { settingsSheet }
    }

    @ChartContentBuilder
    private func mark(for slice: Slice) -> some ChartContent {
        let dimmed = selectedID != nil && selectedID != slice.id
        switch chartKind {
        case .donut, .pie:
            SectorMark(angle: .value("Total", slice.value), innerRadius: .ratio(chartKind == .donut ? 0.62 : 0), angularInset: 1.5)
                .foregroundStyle(slice.color)
                .opacity(dimmed ? 0.35 : 1)
                .cornerRadius(4)
        case .bar:
            BarMark(x: .value("Category", slice.category.name), y: .value("Total", slice.value))
                .foregroundStyle(slice.color)
                .opacity(dimmed ? 0.35 : 1)
                .cornerRadius(6)
        case .horizontalBar:
            BarMark(x: .value("Total", slice.value), y: .value("Category", slice.category.name))
                .foregroundStyle(slice.color)
                .opacity(dimmed ? 0.35 : 1)
                .cornerRadius(6)
        case .stackedBar:
            BarMark(x: .value("Total", slice.value), y: .value("Spending", "This month"))
                .foregroundStyle(slice.color)
                .opacity(dimmed ? 0.35 : 1)
                .cornerRadius(4)
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch chartKind {
        case .donut, .pie:
            Chart(slices) { mark(for: $0) }
                .chartAngleSelection(value: $angleSelection)
                .onChange(of: angleSelection) { _, value in
                    if let value { selectedID = slice(atCumulative: value)?.id }
                }
        case .bar:
            Chart(barSlices) { mark(for: $0) }
                .chartXSelection(value: Binding(get: { selectedID }, set: { selectedID = $0 }))
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2).foregroundStyle(Palette.inkFaint) } }
        case .horizontalBar:
            Chart(slices) { mark(for: $0) }
                .chartYSelection(value: Binding(get: { selectedID }, set: { selectedID = $0 }))
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption2).foregroundStyle(Palette.inkFaint) } }
        case .stackedBar:
            Chart(slices) { mark(for: $0) }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXSelection(value: $stackSelection)
                .onChange(of: stackSelection) { _, value in
                    if let value { selectedID = slice(atCumulative: value)?.id }
                }
        }
    }

    private func legendRow(_ slice: Slice) -> some View {
        HStack(spacing: 10) {
            Circle().fill(slice.color).frame(width: 11, height: 11)
            Text(slice.category.name).font(.subheadline.weight(.semibold))
            Spacer()
            if let label = label(for: slice) {
                Text(label).font(.subheadline).foregroundStyle(Palette.inkMuted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selectedID == slice.id ? slice.category.soft : .clear, in: .rect(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Chart type") {
                    Picker("Chart type", selection: $chartKind) {
                        ForEach(ChartKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Data labels") {
                    Picker("Data labels", selection: $labelMode) {
                        ForEach(LabelMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Sort") {
                    Picker("Sort", selection: $sort) {
                        ForEach(CategorySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Colors") {
                    Picker("Colors", selection: $paletteMode) {
                        ForEach(PaletteMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Chart settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsOpen = false } }
            }
        }
        .tint(Palette.accent)
        .presentationDetents([.medium, .large])
    }
}
