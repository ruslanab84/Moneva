import SwiftUI
import SwiftData

/// One rate per foreign currency already in the ledger, into the display currency.
struct ExchangeRatesView: View {
    @AppStorage(Money.storageKey) private var currencyCode = Money.code
    @AppStorage(ExchangeRates.storageKey) private var ratesRaw = ""
    @Query private var transactions: [Transaction]
    @State private var texts: [String: String] = [:]

    private var rates: ExchangeRates { ExchangeRates(raw: ratesRaw) }
    private var codes: [String] {
        let rated = rates.rates.keys.filter { $0.hasSuffix(">\(currencyCode)") }.map { String($0.prefix { $0 != ">" }) }
        return Set(transactions.map(\.currency) + rated).subtracting([currencyCode]).sorted()
    }

    var body: some View {
        Form {
            Section {
                if codes.isEmpty {
                    Text("Every transaction is in \(currencyCode). Rates appear here once one is in another currency.")
                        .foregroundStyle(Palette.inkMuted)
                }
                ForEach(codes, id: \.self) { code in
                    HStack {
                        Text("1 \(code) =")
                        TextField("Rate", text: binding(code))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text(currencyCode).foregroundStyle(Palette.inkMuted)
                    }
                }
            } footer: {
                Text("Rates convert totals in Transactions and Ask only. Saved amounts never change; budgets, forecast and accounts stay in their own currency.")
            }
        }
        .navigationTitle("Exchange rates")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ code: String) -> Binding<String> {
        Binding(
            get: { texts[code] ?? rates.rate(from: code, to: currencyCode).map { NSDecimalNumber(decimal: $0).stringValue } ?? "" },
            set: { text in
                texts[code] = text
                var updated = rates
                updated.set(Money.parse(text), from: code, to: currencyCode)
                ratesRaw = updated.raw
            })
    }
}
