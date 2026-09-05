import SwiftUI

struct ScopePicker: View {
    @Binding var scope: Scope

    var body: some View {
        Picker("Scope", selection: $scope) {
            ForEach(Scope.allCases) { value in
                Label(value.title, systemImage: value.symbol).tag(value)
            }
        }
        .pickerStyle(.segmented)
    }
}

struct CategoryBadge: View {
    let category: SpendingCategory?
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: category?.symbol ?? "arrow.down")
            .font(.system(size: size * 0.42))
            .foregroundStyle(category?.tint ?? Palette.accent)
            .frame(width: size, height: size)
            .background(category?.soft ?? Palette.accentSoft, in: .rect(cornerRadius: size * 0.32))
            .accessibilityHidden(true)
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            CategoryBadge(category: transaction.category)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant.isEmpty ? (transaction.category?.name ?? "Transaction") : transaction.merchant)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 8)
            Text(amountText)
                .font(.money(.title3))
                .foregroundStyle(transaction.kind == .income ? Palette.accent : Palette.ink)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var subtitle: String {
        var parts = [transaction.allocations.isEmpty ? (transaction.category?.name ?? "Uncategorised") : transaction.allocations.map { "\($0.category?.name ?? "Uncategorised"): \($0.amount.money(transaction.currency))" }.joined(separator: ", ")]
        parts.append(transaction.date.formatted(date: .omitted, time: .shortened))
        if transaction.scope == .shared { parts.append("Shared") }
        if transaction.source != .manual { parts.append(transaction.source.rawValue) }
        return parts.joined(separator: " · ")
    }

    private var amountText: String {
        (transaction.kind == .income ? "+" : "−") + transaction.amount.money(transaction.currency)
    }

    private var accessibilityLabel: String {
        "\(transaction.merchant), \(transaction.category?.name ?? "uncategorised"), \(amountText), \(transaction.date.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct EmptyHint: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Palette.accent)
            Text(title).font(.headline).foregroundStyle(Palette.ink)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .monevaCard()
    }
}

/// Screen chrome shared by every tab: warm ground, generous top spacing.
struct ScreenScroll<Content: View>: View {
    let title: String
    let eyebrow: String?
    @ViewBuilder var content: Content

    init(title: String, eyebrow: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.eyebrow = eyebrow
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    if let eyebrow { Eyebrow(eyebrow) }
                    Text(title)
                        .font(.money(.largeTitle))
                        .foregroundStyle(Palette.ink)
                }
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .background(Palette.ground)
        .scrollIndicators(.hidden)
    }
}

/// Money input. A `TextField(value:format:)` re-formats the Decimal on every
/// keystroke and drops characters typed during the round-trip, so the field
/// holds plain text and parses on change instead.
struct AmountField: View {
    let title: String
    @Binding var value: Decimal
    /// Read once per field so the symbol matches whatever the settings say.
    var currencyCode: String = Money.code
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, text: $text)
                .keyboardType(.decimalPad)
                .onAppear { text = AmountField.display(value) }
                .onChange(of: text) { _, new in value = AmountField.parse(new) }
                .onChange(of: value) { _, new in
                    if AmountField.parse(text) != new { text = AmountField.display(new) }
                }
            Text(Money.symbol(for: currencyCode))
                .foregroundStyle(Palette.inkMuted)
                .accessibilityHidden(true)
        }
    }

    /// Accepts both decimal separators — the keypad shows whichever the
    /// locale uses.
    static func parse(_ input: String) -> Decimal {
        Money.parse(input) ?? 0
    }

    static func display(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
