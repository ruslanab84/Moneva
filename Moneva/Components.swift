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

struct TypewriterText: View {
    let text: String
    var interval: Double = 0.04
    var animate: Bool = true
    @State private var shownWords: Int
    // The text the reveal already ran for — reappearing (tab switch) must not replay it.
    @State private var revealedText: String?

    init(text: String, interval: Double = 0.04, animate: Bool = true) {
        self.text = text
        self.interval = interval
        self.animate = animate
        _shownWords = State(initialValue: animate ? 0 : Int.max)
    }

    private var words: [String] { text.split(separator: " ").map(String.init) }

    var body: some View {
        Text(words.prefix(shownWords).joined(separator: " "))
            .task(id: text) {
                guard animate else { return }
                if revealedText != text {
                    revealedText = text
                    shownWords = 0
                }
                while shownWords < words.count {
                    shownWords += 1
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            CategoryBadge(category: transaction.category)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant.isEmpty ? (transaction.category?.name ?? String(localized: "Transaction")) : transaction.merchant)
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
        let uncategorised = String(localized: "Uncategorised")
        var parts = [transaction.allocations.isEmpty ? ([transaction.category?.name ?? uncategorised, transaction.subcategory?.name].compactMap { $0 }.joined(separator: " · ")) : transaction.allocations.map { "\($0.category?.name ?? uncategorised): \($0.amount.money(transaction.currency))" }.joined(separator: ", ")]
        parts.append(transaction.date.formatted(date: .omitted, time: .shortened))
        if transaction.scope == .shared {
            // Who entered it beats the bare word "Shared": in a family budget
            // that is the part nobody can infer from the amount.
            parts.append(FamilySyncEngine.shared.memberName(for: transaction.authorID) ?? String(localized: "Shared"))
        }
        if transaction.source != .manual { parts.append(transaction.source.rawValue) }
        return parts.joined(separator: " · ")
    }

    private var amountText: String {
        (transaction.kind == .income ? "+" : "−") + transaction.amount.money(transaction.currency)
    }

    private var accessibilityLabel: String {
        "\(transaction.merchant), \(transaction.category?.name ?? String(localized: "uncategorised")), \(amountText), \(transaction.date.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct EmptyHint: View {
    let title: Text
    let message: Text
    let symbol: String

    init(title: LocalizedStringKey, message: LocalizedStringKey, symbol: String) {
        self.title = Text(title)
        self.message = Text(message)
        self.symbol = symbol
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Palette.accent)
            title.font(.headline).foregroundStyle(Palette.ink)
            message
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
/// `title`/`eyebrow` take `Text` so callers can pass either a localized
/// literal ("Budget") or an already-formatted value (a localized month
/// string) through the same initializer, like `Text` itself does.
struct ScreenScroll<Content: View>: View {
    let title: Text
    let eyebrow: Text?
    @ViewBuilder var content: Content

    init(title: LocalizedStringKey, eyebrow: Text? = nil, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.eyebrow = eyebrow
        self.content = content()
    }

    init<S: StringProtocol>(title: S, eyebrow: Text? = nil, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.eyebrow = eyebrow
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    if let eyebrow {
                        eyebrow
                            .font(.caption2.weight(.semibold))
                            .tracking(1.1)
                            .textCase(.uppercase)
                            .foregroundStyle(Palette.inkFaint)
                    }
                    title
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
    let title: LocalizedStringKey
    @Binding var value: Decimal
    /// Read once per field so the symbol matches whatever the settings say.
    var currencyCode: String = Money.code
    /// Off where a currency picker sits next to the field — code and symbol
    /// twice in one row reads like a bug.
    var showsSymbol = true
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, text: $text)
                .keyboardType(.decimalPad)
                .onAppear { text = AmountField.editable(value) }
                .onChange(of: text) { _, new in value = AmountField.parse(new) }
                .onChange(of: value) { _, new in
                    if AmountField.parse(text) != new { text = AmountField.editable(new) }
                }
            if showsSymbol {
                Text(Money.symbol(for: currencyCode))
                    .foregroundStyle(Palette.inkMuted)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Accepts both decimal separators — the keypad shows whichever the
    /// locale uses.
    static func parse(_ input: String) -> Decimal {
        Money.parse(input) ?? 0
    }

    /// Zero shows as an empty field so the first digit typed replaces it
    /// instead of landing next to a leading "0".
    static func editable(_ value: Decimal) -> String {
        value == 0 ? "" : display(value)
    }

    static func display(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}

/// The amount is the point of this screen, so it gets the serif face and the
/// whole card instead of one anonymous form row.
struct AmountHero: View {
    @Binding var draft: TransactionDraft
    var allowKind = true
    /// Overrides the expense/income caption where the screen already says
    /// what the money is — a receipt total, say.
    var eyebrow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if allowKind {
                Picker("Kind", selection: $draft.kind) {
                    ForEach(TransactionKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(eyebrow ?? (draft.kind == .income ? "Income amount" : "Expense amount"))
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    AmountField(title: "0", value: $draft.amount, currencyCode: draft.currency, showsSymbol: false)
                        .font(.money(.largeTitle))
                        .foregroundStyle(draft.kind == .income ? Palette.accent : Palette.ink)
                    Picker("Currency", selection: $draft.currency) {
                        ForEach(Money.pickerCodes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.footnote.weight(.semibold))
                }
            }
        }
        .monevaCard()
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}
