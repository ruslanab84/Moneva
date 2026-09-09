import SwiftUI

struct SmartInsightsPreview: View {
    let input: InsightInput
    @State private var signals: [SpendingSignal] = []
    @State private var processed: InsightInput?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.headline)
                .foregroundStyle(Palette.accent)

            Text("Smart insights")
                .font(.headline)
                .foregroundStyle(Palette.ink)

            if processed != input {
                Text("Checking your spending patterns…")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
            } else if let signal = signals.first {
                Text(signal.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(3)
                Text(signal.explanations[0])
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(4)
            } else {
                Text("No significant changes detected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text("Keep recording expenses to reveal new patterns.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
            }

            Spacer(minLength: 6)
            Label("View", systemImage: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Palette.accentSoft, in: .capsule)
        }
        .frame(maxWidth: .infinity, minHeight: 246, maxHeight: 246, alignment: .topLeading)
        .monevaCard(padding: 16)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the smart insights details")
        .task(id: input) {
            let snapshot = input
            let work = Task.detached(priority: .utility) { InsightEngine.detect(snapshot) }
            let detected = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            signals = detected
            processed = snapshot
        }
    }
}

struct SmartInsightsView: View {
    let input: InsightInput
    @State private var signals: [SpendingSignal] = []
    @State private var explanations: [String: String] = [:]
    @State private var processed: InsightInput?
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(Palette.accent)
                Eyebrow("Smart insights · \(input.currency)")
            }
            if processed != input {
                Text("Checking your spending patterns…")
                    .font(.subheadline).foregroundStyle(Palette.inkMuted)
            } else if signals.isEmpty {
                Text("No significant changes detected")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                Text("Insights appear when there is enough recorded spending to compare. Trends need three months of history and seven completed days this month.")
                    .font(.footnote).foregroundStyle(Palette.inkMuted)
            } else {
                ForEach(signals) { signal in
                    if signal.id != signals.first?.id { Divider().overlay(Palette.line) }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: signal.kind == .onTrack ? "checkmark.circle" : signal.kind == .decrease ? "arrow.down.right" : "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(signal.kind == .decrease || signal.kind == .onTrack ? Palette.accent : Palette.warning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(signal.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                            let explanation = explanations[signal.id]
                            Text(explanation ?? signal.explanations[0])
                                .font(.footnote).foregroundStyle(Palette.inkMuted)
                                .redacted(reason: explanation == nil ? .placeholder : [])
                                .opacity(explanation == nil && pulse ? 0.45 : 1)
                                .animation(explanation == nil ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .easeInOut(duration: 0.2), value: pulse)
                                .animation(.easeInOut(duration: 0.2), value: explanation)
                                .accessibilityLabel(explanation ?? "Writing the explanation")
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .monevaCard()
        .onAppear { pulse = true }
        .task(id: input) {
            explanations = [:]
            let snapshot = input
            let work = Task.detached(priority: .utility) { InsightEngine.detect(snapshot) }
            let detected = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            signals = detected
            processed = snapshot
            for signal in detected {
                let explanation = await InsightExplainer.explain(signal)
                guard !Task.isCancelled else { return }
                explanations[signal.id] = explanation
            }
        }
    }
}

#if DEBUG
#Preview("Light · narrow", traits: .fixedLayout(width: 320, height: 700)) {
    ScrollView { SmartInsightsView(input: smartInsightsPreviewInput).padding(20) }
        .background(Palette.ground).preferredColorScheme(.light)
}

#Preview("Dark · accessibility", traits: .fixedLayout(width: 430, height: 932)) {
    ScrollView { SmartInsightsView(input: .init(entries: [], limits: [], currency: "USD", day: .now)).padding(20) }
        .background(Palette.ground).preferredColorScheme(.dark).environment(\.dynamicTypeSize, .accessibility1)
}

@MainActor
var smartInsightsPreviewInput: InsightInput {
    let calendar = Calendar.current
    func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }
    let entries = (6...9).flatMap { month in
        (1...3).map { day in
            InsightEntry(categoryID: "restaurant", category: "Restaurant", amount: month == 9 ? 134 : 100, date: date(month, day))
        }
    }
    return InsightInput(entries: entries, limits: [], currency: "USD", day: date(9, 15))
}
#endif
