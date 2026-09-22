import Foundation

/// The reverse of StatementImport: ordinary Transactions out to a CSV file,
/// so a user can back up or move data into a spreadsheet. Pure Swift string
/// building — no model, no SwiftData writes.
enum TransactionExport {

    static func csv(_ transactions: [Transaction]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var lines = ["Date,Merchant,Category,Amount,Currency,Kind,Scope,Note"]
        for transaction in transactions.sorted(by: { $0.date < $1.date }) {
            let fields = [
                formatter.string(from: transaction.date),
                transaction.merchant,
                transaction.category?.name ?? "",
                "\(transaction.amount)",
                transaction.currency,
                transaction.kind.rawValue,
                transaction.scope.rawValue,
                transaction.note,
            ]
            lines.append(fields.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n")
    }

    private static func field(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Writes to a fresh temp file each call so re-exports never collide with
    /// one already handed to a Share Sheet.
    static func write(_ transactions: [Transaction]) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "moneva-export-\(Int(Date.now.timeIntervalSince1970)).csv")
        try csv(transactions).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
