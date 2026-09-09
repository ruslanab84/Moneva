import Foundation

/// CSV / bank-statement parsing. Pure Swift over strings — no SwiftData, no
/// model, no arithmetic beyond reading one number out of one cell. The rows it
/// produces become ordinary `TransactionDraft`s, so every downstream guard
/// (`Money.valid`, `CategoryLibrary.isSelectable`, `DraftStore.save`) still
/// applies exactly as it does for voice and receipt drafts.
enum StatementImport {

    // MARK: - Reading the file

    /// Statements come out of banks in whatever the teller's Windows box used.
    /// UTF-8 first, then the two encodings that actually show up.
    static func text(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// The delimiter is whichever of `,` `;` `\t` occurs most in the header
    /// line — a European statement uses `;` because `,` is its decimal mark.
    static func delimiter(_ text: String) -> Character {
        let header = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let counts: [(Character, Int)] = [",", ";", "\t"].map { candidate in
            (candidate, header.filter { $0 == candidate }.count)
        }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    /// RFC 4180: quoted fields may contain the delimiter, newlines, and `""`
    /// for a literal quote. Blank lines are dropped.
    static func fields(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() { row.append(field.trimmingCharacters(in: .whitespaces)); field = "" }
        func endRow() {
            endField()
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(character) }
                continue
            }
            switch character {
            case "\"" where field.isEmpty: quoted = true
            case delimiter: endField()
            case "\r": break
            case "\n": endRow()
            default: field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    // MARK: - Column mapping

    enum SignRule: String, CaseIterable, Identifiable {
        /// A negative amount is money leaving, a positive one is money arriving.
        case signed
        /// Separate Debit / Credit columns: every value in the picked column is
        /// the same direction, so import the file twice, once per column.
        case allExpense
        case allIncome
        var id: String { rawValue }
    }

    struct Mapping: Equatable {
        var date: Int
        var merchant: Int
        var amount: Int
        /// `nil` = the file names no currency, so the active one is assumed.
        var currency: Int?
        var sign: SignRule = .signed
    }

    private static let dateHeaders = ["date", "дата", "transaction date", "booking date", "posted", "value date", "tarix"]
    private static let merchantHeaders = ["description", "merchant", "payee", "name", "details", "narrative", "назначение", "описание", "получатель", "təyinat"]
    private static let amountHeaders = ["amount", "sum", "value", "сумма", "məbləğ", "debit", "withdrawal"]
    private static let currencyHeaders = ["currency", "ccy", "валюта", "valyuta"]

    /// A header row is only a header when it names at least a date and an
    /// amount. A file that starts straight with data gets `nil` and the user
    /// picks columns by hand.
    static func guessMapping(header: [String]) -> Mapping? {
        func find(_ candidates: [String]) -> Int? {
            let folded = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            if let exact = folded.firstIndex(where: { candidates.contains($0) }) { return exact }
            return folded.firstIndex { cell in candidates.contains { !cell.isEmpty && cell.contains($0) } }
        }
        guard let date = find(dateHeaders), let amount = find(amountHeaders) else { return nil }
        let merchant = find(merchantHeaders) ?? header.indices.first { $0 != date && $0 != amount } ?? date
        return Mapping(date: date, merchant: merchant, amount: amount, currency: find(currencyHeaders))
    }

    // MARK: - Cells

    private static let junk = CharacterSet(charactersIn: " \u{00a0}\u{202f}'’ ").union(.letters).union(.symbols).subtracting(CharacterSet(charactersIn: "-+"))

    /// Signed, because the sign is the only thing telling expense from income.
    /// Handles `1 234,56`, `1,234.56`, `(45.00)`, `-12.30 USD`, `12.30-`.
    /// ponytail: a lone separator with exactly three digits behind it is read as
    /// a thousands mark, so `1,500` is fifteen hundred, never one and a half.
    /// Statements that print `1,500` meaning 1.5 need an explicit format hint.
    static func amount(_ text: String) -> Decimal? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        var negative = false
        if cleaned.hasPrefix("(") && cleaned.hasSuffix(")") {
            negative = true
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        if cleaned.hasSuffix("-") { negative = true; cleaned = String(cleaned.dropLast()) }
        cleaned = cleaned.components(separatedBy: junk).joined()
        if cleaned.hasPrefix("-") { negative = true; cleaned = String(cleaned.dropFirst()) }
        if cleaned.hasPrefix("+") { cleaned = String(cleaned.dropFirst()) }

        let lastComma = cleaned.lastIndex(of: ",")
        let lastDot = cleaned.lastIndex(of: ".")
        var decimalMark: Character?
        switch (lastComma, lastDot) {
        case let (comma?, dot?): decimalMark = comma > dot ? "," : "."
        case let (comma?, nil): decimalMark = cleaned.distance(from: comma, to: cleaned.endIndex) == 4 ? nil : ","
        case let (nil, dot?): decimalMark = cleaned.distance(from: dot, to: cleaned.endIndex) == 4 ? nil : "."
        case (nil, nil): decimalMark = nil
        }
        var digits = ""
        for character in cleaned {
            if character == decimalMark { digits.append(".") }
            else if character.isNumber { digits.append(character) }
        }
        guard !digits.isEmpty, digits != ".",
              let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN
        else { return nil }
        return negative ? -value : value
    }

    /// ponytail: a fixed format list, tried in order. `03/04/2026` is read as
    /// 3 April, the day-first reading, because that is what the statements this
    /// app sees print; a per-file date-format picker is the upgrade if a
    /// month-first bank shows up.
    static let dateFormats = ["yyyy-MM-dd", "yyyy/MM/dd", "dd.MM.yyyy", "dd/MM/yyyy", "dd-MM-yyyy", "dd.MM.yy", "dd/MM/yy", "MM/dd/yyyy", "yyyyMMdd"]

    static func date(_ text: String, calendar: Calendar = .current) -> Date? {
        // Statements often print "2026-09-14 13:02" — the day is all we keep.
        let day = String(text.trimmingCharacters(in: .whitespaces).prefix(while: { $0 != " " && $0 != "T" }))
        guard !day.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in dateFormats {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: day) { return calendar.startOfDay(for: parsed) }
        }
        return nil
    }

    // MARK: - Rows

    struct Row: Identifiable, Equatable {
        var id = UUID()
        var date: Date
        var merchant: String
        var amount: Decimal
        var kind: TransactionKind
        var currency: String
    }

    /// Unreadable lines are skipped, not guessed at: a row whose date or amount
    /// cannot be read carries no information worth saving.
    static func rows(_ fields: [[String]], mapping: Mapping, defaultCurrency: String = Money.code,
                     skipFirst: Bool, calendar: Calendar = .current) -> [Row] {
        var rows: [Row] = []
        for line in fields.dropFirst(skipFirst ? 1 : 0) {
            func cell(_ index: Int?) -> String {
                guard let index, line.indices.contains(index) else { return "" }
                return line[index]
            }
            guard let date = date(cell(mapping.date), calendar: calendar),
                  let signed = amount(cell(mapping.amount)), signed != 0 else { continue }
            let kind: TransactionKind
            switch mapping.sign {
            case .signed: kind = signed < 0 ? .expense : .income
            case .allExpense: kind = .expense
            case .allIncome: kind = .income
            }
            let currency = cell(mapping.currency).uppercased()
            rows.append(Row(date: date,
                            merchant: cell(mapping.merchant),
                            amount: abs(signed),
                            kind: kind,
                            currency: Money.pickerCodes.contains(currency) ? currency : defaultCurrency))
        }
        return rows
    }

    /// Re-importing an overlapping statement is the normal case, not the odd
    /// one — so a row that matches an existing transaction on day, currency,
    /// signed amount and folded merchant is pre-unticked rather than silently
    /// dropped: only the user knows whether they really bought the same coffee
    /// twice that day.
    static func isDuplicate(_ row: Row, of transaction: Transaction, calendar: Calendar = .current) -> Bool {
        transaction.amount == row.amount && transaction.kind == row.kind
            && transaction.currency == row.currency
            && calendar.isDate(transaction.date, inSameDayAs: row.date)
            && CategoryLibrary.fold(transaction.merchant) == CategoryLibrary.fold(row.merchant)
    }
}
