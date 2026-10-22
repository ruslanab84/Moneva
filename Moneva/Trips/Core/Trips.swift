import Foundation

/// Trip mode. While a trip is active, new entries default to its currency and
/// carry its tag. Nothing is converted: a trip's totals are one line per
/// currency, the same strict path budgets use.
enum Trips {
    /// The active trip's `cloudID`, and its currency. Both live in defaults
    /// because a `TransactionDraft` is built without a `ModelContext`.
    static let activeKey = "trip.active"
    static let currencyKey = "trip.currency"

    static var activeID: UUID? {
        UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
    }

    /// The one answer to "which currency does a new entry log in?".
    static var entryCurrency: String {
        activeID == nil ? Money.code : UserDefaults.standard.string(forKey: currencyKey) ?? Money.code
    }

    static func isActive(_ trip: Trip) -> Bool { trip.cloudID == activeID }

    /// One trip at a time: any other still-open trip in `all` ends now.
    static func start(_ trip: Trip, endingOthersIn all: [Trip] = [], now: Date = .now) {
        for other in all where other !== trip && other.endDate == nil { other.endDate = max(now, other.startDate) }
        trip.endDate = nil
        UserDefaults.standard.set(trip.cloudID.uuidString, forKey: activeKey)
        UserDefaults.standard.set(trip.currency, forKey: currencyKey)
    }

    static func end(_ trip: Trip, now: Date = .now) {
        trip.endDate = max(now, trip.startDate)
        if isActive(trip) {
            UserDefaults.standard.removeObject(forKey: activeKey)
            UserDefaults.standard.removeObject(forKey: currencyKey)
        }
    }

    /// One line per currency, largest first, never converted.
    static func totals(_ transactions: [Transaction], trip: Trip, scope: Scope, kind: TransactionKind = .expense) -> [(currency: String, amount: Decimal)] {
        let tagged = transactions.filter { $0.trip === trip }
        let everything = Date.distantPast..<Date.distantFuture
        var lines: [(currency: String, amount: Decimal)] = []
        for code in Set(tagged.map(\.currency)) {
            let amount = kind == .expense
                ? Budgeting.spent(tagged, in: everything, scope: scope, currency: code)
                : Budgeting.earned(tagged, in: everything, scope: scope, currency: code)
            if amount > 0 { lines.append((code, amount)) }
        }
        return lines.sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.currency < $1.currency }
    }
}

#if DEBUG
func tripsSelfCheck() {
    let paris = Trip(name: "Paris", currency: "EUR")
    let rome = Trip(name: "Rome", currency: "EUR")
    func tagged(_ amount: Decimal, _ currency: String, trip: Trip?, kind: TransactionKind = .expense, scope: Scope = .personal) -> Transaction {
        let tx = Transaction(amount: amount, merchant: "x", kind: kind, scope: scope, category: nil, currency: currency)
        tx.trip = trip
        return tx
    }
    let rows = [
        tagged(10, "EUR", trip: paris), tagged(Decimal(string: "5.50")!, "EUR", trip: paris), tagged(20, "USD", trip: paris),
        tagged(99, "EUR", trip: nil), tagged(99, "EUR", trip: rome),
        tagged(99, "EUR", trip: paris, scope: .shared), tagged(7, "EUR", trip: paris, kind: .income),
    ]
    let spent = Trips.totals(rows, trip: paris, scope: .personal)
    assert(spent.map(\.currency) == ["USD", "EUR"] && spent.map(\.amount) == [20, Decimal(string: "15.50")!],
           "trip totals stay one line per currency, unconverted, and skip untagged, other-trip, other-scope and income rows")
    assert(Trips.totals(rows, trip: paris, scope: .personal, kind: .income).map(\.amount) == [7], "trip income is its own total")
    assert(Trips.totals(rows, trip: paris, scope: .shared).map(\.amount) == [99], "shared trip spending stays in its own partition")

    let defaults = UserDefaults.standard
    let saved = (defaults.string(forKey: Trips.activeKey), defaults.string(forKey: Trips.currencyKey))
    defaults.removeObject(forKey: Trips.activeKey)
    assert(Trips.entryCurrency == Money.code, "with no active trip, entries log in the display currency")
    Trips.start(paris)
    assert(Trips.entryCurrency == "EUR" && Trips.activeID == paris.cloudID, "an active trip sets the entry currency")
    Trips.end(rome)
    assert(Trips.activeID == paris.cloudID, "ending another trip leaves the active one alone")
    rome.endDate = nil
    Trips.start(paris, endingOthersIn: [paris, rome])
    assert(rome.endDate != nil && paris.endDate == nil, "starting a trip closes any other open one")
    Trips.end(paris)
    assert(Trips.activeID == nil && Trips.entryCurrency == Money.code && paris.endDate != nil, "ending the trip restores the display currency")
    defaults.set(saved.0, forKey: Trips.activeKey)
    defaults.set(saved.1, forKey: Trips.currencyKey)
}
#endif
