import Foundation

/// Balances, in Swift, like every other number in the app. An account's balance
/// is only ever made of money in that account's own currency — a transaction
/// recorded in another currency is not converted, it is not counted.
enum Accounts {
    /// Identity, not `persistentModelID`: every caller passes rows from one
    /// context, and `===` is also correct for objects not yet inserted, which
    /// is what the self-check builds.
    static func balance(_ account: Account, transactions: [Transaction], transfers: [Transfer]) -> Decimal {
        var total = account.openingBalance
        for transaction in transactions where transaction.account === account && transaction.currency == account.currency {
            total += transaction.signedAmount
        }
        for transfer in transfers where transfer.currency == account.currency {
            if transfer.from === account { total -= transfer.amount }
            if transfer.to === account { total += transfer.amount }
        }
        return total
    }

    /// Archived accounts leave the pickers. Same shape as `CategoryLibrary.visible`.
    static func visible(_ all: [Account]) -> [Account] {
        all.filter { !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func nextSortIndex(_ all: [Account]) -> Int { (all.map(\.sortIndex).max() ?? -1) + 1 }

    /// Two different live accounts, same currency, a real amount. No conversion,
    /// so a cross-currency move is two separate transactions, not a transfer.
    static func canTransfer(from source: Account?, to target: Account?, amount: Decimal) -> Bool {
        guard let source, let target, source !== target else { return false }
        guard source.currency == target.currency, Money.valid(amount, currency: source.currency) else { return false }
        return true
    }

    /// The account a recurring charge may actually land in. An account holds
    /// only its own currency, so a subscription whose price is in another one
    /// leaves no balance — the charge is still recorded, just unattributed.
    static func holder(_ account: Account?, currency: String) -> Account? {
        guard let account, account.currency == currency else { return nil }
        return account
    }

    static func recent(_ transfers: [Transfer], limit: Int = 10) -> [Transfer] {
        transfers.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }
}
