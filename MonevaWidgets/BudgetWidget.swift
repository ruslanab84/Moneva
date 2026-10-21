import AppIntents
import SwiftUI
import WidgetKit

struct BudgetEntry: TimelineEntry {
    var date: Date
    var snapshot: BudgetSnapshot?
}

/// Reads the snapshot the app writes after every save; the app also asks WidgetKit
/// to reload then. The midnight refresh only matters for the month boundary.
struct BudgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetEntry { BudgetEntry(date: .now, snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (BudgetEntry) -> Void) {
        completion(context.isPreview ? BudgetEntry(date: .now, snapshot: .sample) : entry(now: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetEntry>) -> Void) {
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now.addingTimeInterval(86_400)
        completion(Timeline(entries: [entry(now: .now)], policy: .after(midnight)))
    }

    private func entry(now: Date) -> BudgetEntry {
        // Last month's numbers would mislead on the 1st — show the empty state until the app writes this month.
        let snapshot = BudgetSnapshot.load().flatMap { Calendar.current.isDate($0.monthStart, equalTo: now, toGranularity: .month) ? $0 : nil }
        return BudgetEntry(date: now, snapshot: snapshot)
    }
}

struct BudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RuslanAbd.Moneva.budget", provider: BudgetProvider()) { entry in
            BudgetWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetPalette.ground }
        }
        .configurationDisplayName("Budget")
        .description("What's left of this month's budget.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct BudgetWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: BudgetEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryCircular: circular(snapshot)
            case .accessoryRectangular: rectangular(snapshot)
            case .accessoryInline: Text(headline(snapshot)).privacySensitive()
            case .systemMedium: medium(snapshot)
            default: small(snapshot)
            }
        } else {
            empty
        }
    }

    private func headline(_ snapshot: BudgetSnapshot) -> LocalizedStringKey {
        snapshot.isOver ? "\(snapshot.left) over" : "\(snapshot.left) left"
    }

    private func percent(_ progress: Double) -> String {
        (progress).formatted(.percent.precision(.fractionLength(0)))
    }

    private func circular(_ snapshot: BudgetSnapshot) -> some View {
        Gauge(value: min(snapshot.progress, 1)) {
            Image(systemName: "chart.pie")
        } currentValueLabel: {
            Text(Int((snapshot.progress * 100).rounded()), format: .number)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .accessibilityLabel(Text("Budget used \(percent(snapshot.progress))"))
    }

    private func rectangular(_ snapshot: BudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.shared ? "Shared budget" : "Budget").font(.caption2.weight(.semibold))
            Text(headline(snapshot)).font(.headline).privacySensitive()
            Gauge(value: min(snapshot.progress, 1)) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func small(_ snapshot: BudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.shared ? "Shared budget" : "Budget")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetPalette.inkMuted)
                Spacer()
                addButton
            }
            Spacer(minLength: 0)
            Text(headline(snapshot))
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(snapshot.isOver ? WidgetPalette.over : WidgetPalette.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .privacySensitive()
            Bar(progress: snapshot.progress, tint: WidgetPalette.tint(snapshot.state))
            Text("\(percent(snapshot.progress)) of \(snapshot.total)")
                .font(.caption2)
                .foregroundStyle(WidgetPalette.inkMuted)
                .lineLimit(1)
                .privacySensitive()
        }
    }

    private func medium(_ snapshot: BudgetSnapshot) -> some View {
        HStack(spacing: 16) {
            small(snapshot)
            if !snapshot.categories.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshot.categories) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: row.symbol).font(.caption2).foregroundStyle(Color(hex: row.tintHex))
                                Text(row.name).font(.caption.weight(.semibold)).foregroundStyle(WidgetPalette.ink).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(percent(row.progress)).font(.caption2).foregroundStyle(WidgetPalette.inkMuted)
                            }
                            Bar(progress: row.progress, tint: row.progress >= 1 ? WidgetPalette.over : Color(hex: row.tintHex))
                        }
                        .privacySensitive()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch family {
        case .accessoryInline: Text("No budget yet")
        case .accessoryCircular: Image(systemName: "chart.pie")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Budget").font(.caption2.weight(.semibold))
                Text("Set one in Ledgea").font(.headline)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "chart.pie").foregroundStyle(WidgetPalette.accent)
                    Spacer()
                    addButton
                }
                Spacer(minLength: 0)
                Text("No budget this month").font(.headline).foregroundStyle(WidgetPalette.ink)
                Text("Open Ledgea to set one.").font(.caption).foregroundStyle(WidgetPalette.inkMuted)
            }
        }
    }

    private var addButton: some View {
        Button(intent: AddTransactionIntent()) {
            Image(systemName: "plus")
                .font(.caption.weight(.bold))
                .foregroundStyle(WidgetPalette.card)
                .frame(width: 26, height: 26)
                .background(WidgetPalette.accent, in: .rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add transaction")
    }
}

private struct Bar: View {
    var progress: Double
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.line)
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

/// Hand-copied from `Palette` in Theme.swift (the extension can't import the app module).
enum WidgetPalette {
    static let ground = adaptive("F6F4F0", "131311")
    static let card = adaptive("FFFFFF", "1E1D1A")
    static let ink = adaptive("1C1A17", "F2EFE9")
    static let inkMuted = adaptive("6E6860", "A29B90")
    static let line = adaptive("E8E4DC", "302E29")
    static let accent = adaptive("24544A", "7FBFA8")
    static let warning = adaptive("8F6115", "D6A855")
    static let over = adaptive("B4552F", "E08A63")

    static func tint(_ state: BudgetSnapshot.State) -> Color {
        switch state {
        case .ok: accent
        case .near: warning
        case .over: over
        }
    }

    private static func adaptive(_ light: String, _ dark: String) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

extension BudgetSnapshot {
    static let sample = BudgetSnapshot(
        monthStart: .now, shared: false, left: "₼420.00", isOver: false, total: "₼1,000.00", progress: 0.58, state: .ok,
        categories: [
            Row(name: "Food", symbol: "fork.knife", tintHex: "B5813F", progress: 0.82, text: "₼492 / ₼600"),
            Row(name: "Transport", symbol: "car", tintHex: "4F6D8A", progress: 0.4, text: "₼40 / ₼100"),
        ])
}

#Preview(as: .systemMedium) {
    BudgetWidget()
} timeline: {
    BudgetEntry(date: .now, snapshot: .sample)
    BudgetEntry(date: .now, snapshot: nil)
}
