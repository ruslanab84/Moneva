import SwiftUI

struct FinancialForecastPreview: View {
    let forecast: Budgeting.Forecast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.headline)
                .foregroundStyle(Palette.accent)

            Text("Financial forecast")
                .font(.headline)
                .foregroundStyle(Palette.ink)

            if let available = forecast.available {
                Text("≈ \(available.money(forecast.currency))")
                    .font(.money(.title2))
                    .foregroundStyle(available < 0 ? Palette.warning : Palette.ink)
                Text(available < 0 ? "Projected shortfall" : "Available at month end")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
            } else {
                Text("Building your forecast")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
            }

            Spacer(minLength: 6)
            previewAction
        }
        .frame(maxWidth: .infinity, minHeight: 246, maxHeight: 246, alignment: .topLeading)
        .monevaCard(padding: 16)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the financial forecast details")
    }

    private var previewAction: some View {
        Label("View", systemImage: "arrow.up.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.accentSoft, in: .capsule)
    }
}

struct FinancialForecastView: View {
    let forecast: Budgeting.Forecast
    @State private var explanation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(Palette.accent)
                Eyebrow("Financial forecast · \(forecast.currency)")
            }
            Text("End of month forecast")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
            if let available = forecast.available {
                Text("≈ \(available.money(forecast.currency))")
                    .font(.money(.largeTitle))
                    .foregroundStyle(available < 0 ? Palette.warning : Palette.ink)
                Text(available < 0 ? "Projected shortfall" : "Available")
                    .font(.footnote).foregroundStyle(Palette.inkMuted)
            } else {
                Text("Building your forecast")
                    .font(.headline).foregroundStyle(Palette.ink)
            }
            VStack(spacing: 10) {
                row("Recorded balance", forecast.balance.money(forecast.currency))
                row("Expected income", "+ \(forecast.income.money(forecast.currency))")
                row("Upcoming subscriptions", "− \(forecast.subscriptions.money(forecast.currency))")
                row("Remaining expenses", forecast.expenses.map { "− ≈ \($0.money(forecast.currency))" } ?? "Not enough history")
            }
            Divider().overlay(Palette.line)
            Text(explanation ?? forecast.signal.explanations[0])
                .font(.footnote).foregroundStyle(Palette.inkMuted)
            Text("Balance uses recorded income minus expenses. Add a future-dated income, or set up a recurring income subscription, to include expected salary. Estimates are based only on your records.")
                .font(.caption).foregroundStyle(Palette.inkMuted)
        }
        .monevaCard()
        .task(id: forecast) {
            explanation = nil
            let result = await InsightExplainer.explain(forecast.signal)
            guard !Task.isCancelled else { return }
            explanation = result
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(Palette.inkMuted)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}
