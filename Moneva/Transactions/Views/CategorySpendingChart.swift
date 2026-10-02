import SwiftUI
import Charts

/// This month's spending broken down by category, with a settings sheet for
/// how to see it — chart kind, per-slice labels, sort, and color source.
/// Swift decides every number here; the view only picks how to draw it.
struct CategorySpendingChart: View {
    let data: [(category: SpendingCategory, total: Decimal)]
    let currencyCode: String

    enum ChartKind: String, CaseIterable, Identifiable {
        case petal = "Flower", donut = "Donut", pie = "Pie", bar = "Bar", horizontalBar = "Horizontal", stackedBar = "Stacked"
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

    @State private var chartKind: ChartKind = .petal
    @State private var labelMode: LabelMode = .percent
    @State private var sort: CategorySort = .descending
    @State private var paletteMode: PaletteMode = .categoryTint
    @State private var settingsOpen = false
    @State private var detailOpen = false
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
                .frame(height: chartKind == .stackedBar ? 36 : chartKind == .bar || chartKind == .horizontalBar ? 160 : chartKind == .petal ? 330 : 190)
                // Overlay, not onTapGesture on the chart: Swift Charts selection
                // gestures swallow taps, so only the Canvas petal chart opened.
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { detailOpen = true }
                }
                .animation(.snappy(duration: 0.35), value: chartKind)
                .animation(.snappy(duration: 0.35), value: sort)
                .animation(.snappy(duration: 0.35), value: paletteMode)
        }
        .monevaCard(padding: 16)
        .sheet(isPresented: $settingsOpen) { settingsSheet }
        .sheet(isPresented: $detailOpen) { detailSheet }
    }

    @ChartContentBuilder
    private func mark(for slice: Slice) -> some ChartContent {
        let dimmed = selectedID != nil && selectedID != slice.id
        switch chartKind {
        case .petal:
            // Never rendered — the `chart` view draws petals with Canvas, not marks.
            PointMark(x: .value("x", 0), y: .value("y", 0)).opacity(0)
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

    /// Apple Health-style ring: equal rounded-triangle petals around an open
    /// center, one per category, white category icon on each. Custom Canvas
    /// since Swift Charts has no petal mark — no tap-to-select; amounts live
    /// in the detail sheet.
    private func petal(inner: CGFloat, outer: CGFloat, halfAngle: Double, gap: CGFloat) -> Path {
        func lerp(_ p: CGPoint, _ q: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t) }
        // Sides run parallel to the sector boundary, inset by half the gap, so
        // neighbouring petals keep an even gutter; outer corners sit on the rim.
        let side = CGPoint(x: sin(halfAngle), y: -cos(halfAngle))
        let normal = CGPoint(x: -cos(halfAngle), y: -sin(halfAngle))
        let reach = sqrt(outer * outer - gap * gap / 4)
        let apex = CGPoint(x: 0, y: -inner)
        let right = CGPoint(x: side.x * reach + normal.x * gap / 2, y: side.y * reach + normal.y * gap / 2)
        let left = CGPoint(x: -right.x, y: right.y)

        let apexRight = lerp(apex, right, 0.3), sideRight = lerp(right, apex, 0.2)
        let sideLeft = lerp(left, apex, 0.2), apexLeft = lerp(apex, left, 0.3)
        // Rim is a true arc of the outer circle; corners round into it.
        let rightAngle = atan2(right.y, right.x), leftAngle = atan2(left.y, left.x)
        let inset = (rightAngle - leftAngle) * 0.18
        func rim(_ angle: Double) -> CGPoint { CGPoint(x: outer * cos(angle), y: outer * sin(angle)) }

        var path = Path()
        path.move(to: apexRight)
        path.addLine(to: sideRight)
        path.addQuadCurve(to: rim(rightAngle - inset), control: right)
        for step in 1...16 {
            path.addLine(to: rim(rightAngle - inset - (rightAngle - leftAngle - 2 * inset) * Double(step) / 16))
        }
        path.addQuadCurve(to: sideLeft, control: left)
        path.addLine(to: apexLeft)
        path.addQuadCurve(to: apexRight, control: apex)
        path.closeSubpath()
        return path
    }

    private func drawPetals(context: GraphicsContext, size: CGSize) {
        // Reuses the bar chart's top-5-plus-Others cap (barSlices) — a ring with
        // 10+ thin petals is as unreadable as the bar chart's overlapping labels.
        let petals = barSlices
        guard !petals.isEmpty else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2
        let inner = outer * 0.3
        let angleStep = 2 * Double.pi / Double(petals.count)
        let halfAngle = min(angleStep / 2, .pi / 6)
        let shape = petal(inner: inner, outer: outer, halfAngle: halfAngle, gap: outer * 0.03)
        for (index, slice) in petals.enumerated() {
            let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angleStep * Double(index))
            context.fill(shape.applying(transform), with: .color(slice.color))

            var icon = context.resolve(Image(systemName: slice.category.symbol))
            icon.shading = .color(.white)
            let iconRadius = inner + (outer - inner) * 0.4
            let angle = angleStep * Double(index) - .pi / 2
            context.draw(icon, at: CGPoint(x: center.x + iconRadius * CGFloat(cos(angle)), y: center.y + iconRadius * CGFloat(sin(angle))))
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch chartKind {
        case .petal:
            Canvas { context, size in drawPetals(context: context, size: size) }
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

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    chart
                        .frame(height: chartKind == .stackedBar ? 48 : chartKind == .bar || chartKind == .horizontalBar ? 200 : 240)

                    VStack(spacing: 10) {
                        ForEach(slices) { slice in
                            legendRow(slice)
                                .onTapGesture { selectedID = selectedID == slice.id ? nil : slice.id }
                        }
                    }
                    .animation(.snappy(duration: 0.35), value: sort)
                }
                .padding(16)
            }
            .navigationTitle("Spending by category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { detailOpen = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { settingsOpen = true } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
        }
        .tint(Palette.accent)
        .presentationDetents([.medium, .large])
    }
}
