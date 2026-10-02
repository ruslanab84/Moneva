import SwiftUI

// Design tokens from the Moneva canvas (design/Foundations.dc.html).
enum Palette {
    static let ground = adaptive("F6F4F0", "131311")
    static let card = adaptive("FFFFFF", "1E1D1A")
    static let ink = adaptive("1C1A17", "F2EFE9")
    static let inkMuted = adaptive("6E6860", "A29B90")
    static let inkFaint = adaptive("726C61", "8C867C")
    static let line = adaptive("E8E4DC", "302E29")
    static let accent = adaptive("24544A", "7FBFA8")
    static let accentSoft = adaptive("EAF0ED", "1C2A25")
    static let warning = adaptive("8F6115", "D6A855")
    static let over = adaptive("B4552F", "E08A63")

    static func adaptive(_ light: String, _ dark: String) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Font {
    /// Serif face carries every money value. Text styles keep Dynamic Type working.
    static func money(_ style: Font.TextStyle) -> Font { .system(style, design: .serif) }
}

/// The one currency the app displays in. Amounts keep their own code on the
/// transaction, so switching this never rewrites what already happened.
enum Money {
    static let storageKey = "currency"

    static func parse(_ text: String) -> Decimal? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard text.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }

    static func fractionDigits(_ currency: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.maximumFractionDigits
    }

    static func valid(_ amount: Decimal, currency: String) -> Bool {
        guard !amount.isNaN, amount > 0, amount < Decimal(1_000_000_000_000), pickerCodes.contains(currency) else { return false }
        var original = amount
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &original, fractionDigits(currency), .plain)
        return rounded == amount
    }


    static var code: String {
        get { UserDefaults.standard.string(forKey: storageKey) ?? Locale.current.currency?.identifier ?? "AZN" }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    /// What the current locale prints in front of a number — "₼", "$", "CHF".
    /// Derived from a formatted zero so it follows the same rules as every
    /// amount on screen.
    static func symbol(for code: String) -> String {
        Decimal.zero
            .formatted(.currency(code: code).precision(.fractionLength(0)))
            .filter { !$0.isNumber && !$0.isWhitespace }
    }

    /// The glyph shown beside a code in pickers — never just the code again.
    /// The locale's own symbol wins ("A$"); where it only has the code, fall back
    /// to the narrow form ("₼", "Kz"), then to what the currency's home locale
    /// prints ("د.إ", "Ksh"), then to a short table for the few ICU leaves bare.
    static func displaySymbol(for code: String) -> String {
        let standard = symbol(for: code)
        if standard != code { return standard }
        let narrow = Decimal.zero
            .formatted(.currency(code: code).precision(.fractionLength(0)).presentation(.narrow))
            .filter { !$0.isNumber && !$0.isWhitespace }
        if narrow != code { return narrow }
        if let native = nativeSymbols[code], native != code { return native }
        return fallbackSymbols[code] ?? code
    }

    /// Symbol each currency's home locale prints, stripped of the RTL marks and
    /// spacing ICU wraps around some of them.
    private static let nativeSymbols: [String: String] = {
        var symbols: [String: String] = [:]
        for id in Locale.availableIdentifiers {
            let locale = Locale(identifier: id)
            guard let code = locale.currency?.identifier, let raw = locale.currencySymbol else { continue }
            let symbol = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
                !$0.properties.isWhitespace && $0.properties.generalCategory != .format
            }))
            if !symbol.isEmpty, symbol != code, symbols[code] == nil { symbols[code] = symbol }
        }
        return symbols
    }()

    private static let fallbackSymbols = [
        "ANG": "ƒ", "BGN": "лв", "CVE": "$", "LSL": "L", "RSD": "дин",
        "SLL": "Le", "TMT": "m", "VES": "Bs.", "ZWG": "ZiG",
    ]

    /// "USD $", but plain "CHF" where no distinct symbol exists —
    /// repeating the code twice reads like a bug.
    static func label(for code: String) -> String {
        let symbol = displaySymbol(for: code)
        return symbol == code ? code : "\(code) \(symbol)"
    }

    static let flagRegions = Set(Locale.Region.isoRegions.map(\.identifier))

    /// "🇺🇸" for USD. An ISO 4217 code opens with its ISO 3166 region, so the
    /// flag is those two letters as regional indicators. Codes whose region no
    /// longer exists (ANG) or never did (XAU, gold) have no flag to draw, and
    /// the indicators would render as two empty boxes.
    static func flag(for code: String) -> String {
        let region = code.prefix(2).uppercased()
        guard flagRegions.contains(region) else { return "" }
        var flag = ""
        for scalar in region.unicodeScalars {
            guard (65...90).contains(scalar.value), let indicator = UnicodeScalar(0x1F1E6 + scalar.value - 65) else { return "" }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    /// Codes offered in the picker: the device's own first, then the rest.
    static var pickerCodes: [String] {
        let mine = Locale.current.currency?.identifier
        let rest = Locale.commonISOCurrencyCodes.filter { $0 != mine }
        return ([mine].compactMap { $0 }) + rest
    }
}

/// Light or dark by choice, or whatever the phone is doing. Every colour in
/// `Palette` resolves from the trait collection, so one override covers the app.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "theme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "iphone"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension Decimal {
    /// Formatted with the currency's glyph rather than its code — the locale
    /// prints "AZN 26.50" for anything foreign to it, which reads like a label.
    func money(_ code: String = Money.code) -> String {
        let text = formatted(.currency(code: code))
        let symbol = Money.displaySymbol(for: code)
        return symbol == code ? text : text.replacingOccurrences(of: code, with: symbol)
    }

    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}

struct CardBackground: ViewModifier {
    @ScaledMetric private var scaledPadding: CGFloat
    init(padding: CGFloat = 18) { _scaledPadding = ScaledMetric(wrappedValue: padding) }
    func body(content: Content) -> some View {
        content
            .padding(scaledPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: 24))
            .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 10)
    }
}

extension View {
    func monevaCard(padding: CGFloat = 18) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Small caps section label. Two initialisers — like `Text` itself — so a
/// literal ("Budget") reaches the localization catalog while data already in
/// hand (a category name) renders verbatim instead of doing a doomed catalog
/// lookup on arbitrary user content.
struct Eyebrow: View {
    private let content: Text
    init(_ key: LocalizedStringKey) { content = Text(key) }
    init<S: StringProtocol>(_ content: S) { self.content = Text(content) }

    var body: some View {
        content
            .font(.caption2.weight(.semibold))
            .tracking(1.1)
            .textCase(.uppercase) // locale-correct casing; VoiceOver still reads the natural-case string
            .foregroundStyle(Palette.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Bar that shows budget usage. Exposes its own percentage to VoiceOver —
/// callers that already build an adjacent combined label (e.g. a row using
/// `.accessibilityElement(children: .combine)` with an explicit label) should
/// hide their redundant percent text instead of double-announcing it.
struct ProgressBar: View {
    let progress: Double
    var tint: Color = Palette.accent
    var height: CGFloat = 8
    var accessibilityLabel: LocalizedStringKey = "Progress"

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        return formatter
    }()

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(tint).frame(width: geo.size.width * clamped)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Self.percentFormatter.string(from: NSNumber(value: clamped)) ?? "\(Int((clamped * 100).rounded()))%")
    }
}
