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

    /// "USD $", but plain "AED" where the locale has no distinct symbol —
    /// repeating the code twice reads like a bug.
    static func label(for code: String) -> String {
        let symbol = self.symbol(for: code)
        return symbol == code ? code : "\(code) \(symbol)"
    }

    /// Codes offered in the picker: the device's own first, then the rest.
    static var pickerCodes: [String] {
        let mine = Locale.current.currency?.identifier
        let rest = Locale.commonISOCurrencyCodes.filter { $0 != mine }
        return ([mine].compactMap { $0 }) + rest
    }
}

extension Decimal {
    func money(_ code: String = Money.code) -> String {
        formatted(.currency(code: code).precision(.fractionLength(2)))
    }

    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: 24))
            .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 10)
    }
}

extension View {
    func monevaCard(padding: CGFloat = 18) -> some View { modifier(CardBackground(padding: padding)) }
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(Palette.inkFaint)
    }
}

/// Bar that shows budget usage. Colour never carries the state alone —
/// callers pair it with the amount label.
struct ProgressBar: View {
    let progress: Double
    var tint: Color = Palette.accent
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(tint).frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
