import Foundation
import CloudKit
import SwiftData
import Observation

/// Local ⇄ CloudKit mapping and merge rules for family-shared records.
/// Pure functions only — the stateful `CKSyncEngine` plumbing lives in
/// `FamilySyncEngine` below. Synced: shared Transaction, Budget (with its
/// limits), Settlement, Goal, Subscription, Account and the Transfers that
/// touch a shared account. Never: anything personal, receipts, payments
/// ledgers, reminders.
/// Which side of the share this device is on. The owner keeps the zone in
/// their private database; everyone who accepted the invite reaches the very
/// same zone through the shared database, under the owner's name.
enum FamilyRole: String, Codable {
    case owner, participant
}

/// What Settings shows about sync. Replaces the `print` calls the Phase 1
/// scaffold left behind.
@Observable
final class FamilySyncStatus {
    static let shared = FamilySyncStatus()
    var role: FamilyRole?
    var lastError: String?
    var lastSyncedAt: Date?
    private init() {}
}

/// The family side of a `Budget`, stored as one JSON column and carried as one
/// CKRecord field. Percentages and money are strings/ints only — nothing here
/// ever becomes a `Double`.
struct FamilyBudget: Codable, Equatable {
    /// memberID -> share of every shared expense, summing to 100.
    var splitPercent: [String: Int] = [:]
    /// memberID -> personal monthly ceiling inside the shared total, Decimal as string.
    var allowance: [String: String] = [:]

    static func decode(_ json: String?) -> FamilyBudget {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(FamilyBudget.self, from: data)
        else { return FamilyBudget() }
        return value
    }

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func allowanceAmount(for member: String) -> Decimal? {
        allowance[member].flatMap { Decimal(string: $0) }
    }

    /// An unset split is an equal one. The remainder goes to the first member
    /// in sorted order, so the percentages always add up to exactly 100 and the
    /// answer never depends on dictionary ordering.
    func percent(for member: String, members: [String]) -> Int {
        if let explicit = splitPercent[member] { return explicit }
        let sorted = members.sorted()
        guard !sorted.isEmpty, sorted.contains(member) else { return 0 }
        let even = 100 / sorted.count
        let remainder = 100 - even * sorted.count
        return member == sorted[0] ? even + remainder : even
    }
}

enum FamilySync {
    static let zoneName = "FamilyZone"
    static let transactionRecordType = "Transaction"
    static let budgetRecordType = "Budget"
    static let settlementRecordType = "Settlement"

    /// Deterministic record names keep one record per month per currency —
    /// no cloudID column on `Budget`, no duplicate-budget merge problem.
    static func budgetRecordName(monthStart: Date, currency: String, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: monthStart)
        return String(format: "budget-%@-%04d-%02d", currency, parts.year ?? 0, parts.month ?? 0)
    }

    static func settlementRecordName(_ cloudID: UUID) -> String { "settlement-" + cloudID.uuidString }

    static func zoneID(ownerName: String = CKCurrentUserDefaultName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }

    /// The one rule that made the Phase 1 scaffold unable to sync at all: a
    /// participant's records do not live in a zone they own. Pure, so the
    /// self-check can pin it without touching CloudKit.
    static func zoneID(role: FamilyRole, ownerName: String?) -> CKRecordZone.ID {
        switch role {
        case .owner: return zoneID()
        case .participant: return zoneID(ownerName: ownerName ?? CKCurrentUserDefaultName)
        }
    }

    static func recordID(for cloudID: UUID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: cloudID.uuidString, zoneID: zoneID)
    }

    /// Round-trips through a string so no `Double` ever touches the amount —
    /// CKRecord has no arbitrary-precision decimal field.
    static func encode(_ amount: Decimal) -> String {
        NSDecimalNumber(decimal: amount).stringValue
    }

    static func decodeAmount(_ string: String?) -> Decimal? {
        string.flatMap { Decimal(string: $0) }
    }

    /// Rebuilds the CKRecord from cached system fields when there are any, so
    /// the save carries the correct change tag; otherwise starts a fresh one.
    static func existingOrNewRecord(systemFields: Data?, recordName: String, type: String, zoneID: CKRecordZone.ID) -> CKRecord {
        if let systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
            coder.requiresSecureCoding = true
            if let record = CKRecord(coder: coder) { return record }
        }
        return CKRecord(recordType: type, recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
    }

    static func systemFields(from record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func record(from transaction: Transaction, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = existingOrNewRecord(
            systemFields: transaction.ckSystemFields,
            recordName: transaction.cloudID.uuidString,
            type: transactionRecordType,
            zoneID: zoneID
        )
        record["amount"] = encode(transaction.amount) as CKRecordValue
        record["currency"] = transaction.currency as CKRecordValue
        record["date"] = transaction.date as CKRecordValue
        record["merchant"] = transaction.merchant as CKRecordValue
        record["note"] = transaction.note as CKRecordValue
        record["kind"] = transaction.kind.rawValue as CKRecordValue
        record["source"] = transaction.source.rawValue as CKRecordValue
        record["authorID"] = transaction.authorID as CKRecordValue
        record["accountID"] = sharedAccountID(transaction.account) as CKRecordValue
        writeCategory(transaction.category, to: record)
        return record
    }

    /// Categories travel denormalized: the partner's store has its own
    /// SpendingCategory rows, and syncing those would drag personal-scope
    /// ones along with them.
    static func writeCategory(_ category: SpendingCategory?, to record: CKRecord) {
        record["categoryName"] = (category?.name ?? "") as CKRecordValue
        record["categorySymbol"] = (category?.symbol ?? "") as CKRecordValue
        record["categoryTint"] = (category?.tintHex ?? "") as CKRecordValue
        record["categorySoft"] = (category?.softHex ?? "") as CKRecordValue
    }

    /// A link to an account travels only when that account is itself shared —
    /// a personal account's id, name or balance never leaves the device.
    static func sharedAccountID(_ account: Account?) -> String {
        guard let account, account.scope == .shared else { return "" }
        return account.cloudID.uuidString
    }

    /// The account id a record points at, or nil for none.
    static func accountID(in record: CKRecord, key: String = "accountID") -> UUID? {
        (record[key] as? String).flatMap(UUID.init(uuidString:))
    }

    /// What a record says its category is. `nil` name means the sender had
    /// none — the transaction stays uncategorised, as it always did.
    struct CategoryDescriptor: Equatable {
        var name: String
        var symbol: String
        var tintHex: String
        var softHex: String
        var kind: TransactionKind
    }

    static func categoryDescriptor(from record: CKRecord, kind: TransactionKind) -> CategoryDescriptor? {
        guard let name = record["categoryName"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return CategoryDescriptor(
            name: name,
            symbol: (record["categorySymbol"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "circle",
            tintHex: (record["categoryTint"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "78746A",
            softHex: (record["categorySoft"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "E4E2DB",
            kind: kind
        )
    }

    /// Matches a synced category by name against the shared-scope categories
    /// this device already has. Case- and whitespace-insensitive, because the
    /// two people type their own category names independently.
    static func matchCategory(_ descriptor: CategoryDescriptor, in categories: [SpendingCategory]) -> SpendingCategory? {
        let wanted = descriptor.name.trimmingCharacters(in: .whitespaces).lowercased()
        return categories.first {
            $0.scope == .shared && $0.kind == descriptor.kind && !$0.isArchived
                && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }
    }

    /// A transaction synced in from the partner's device. Category is never
    /// synced (personal-scope categories may not exist on the other device),
    /// so it always lands uncategorised — `TransactionRow` already renders
    /// that cleanly.
    /// ponytail: category stays local-only on sync; add denormalized
    /// categoryName/symbol/tintHex string fields on the CKRecord if partners
    /// need to see categories on shared transactions, never sync
    /// SpendingCategory rows themselves.
    static func makeTransaction(from record: CKRecord, cloudID: UUID) -> Transaction? {
        guard let amount = decodeAmount(record["amount"] as? String),
              let currency = record["currency"] as? String,
              let date = record["date"] as? Date,
              let merchant = record["merchant"] as? String,
              let kindRaw = record["kind"] as? String, let kind = TransactionKind(rawValue: kindRaw),
              let sourceRaw = record["source"] as? String, let source = EntrySource(rawValue: sourceRaw)
        else { return nil }
        let transaction = Transaction(
            amount: amount, date: date, merchant: merchant, note: (record["note"] as? String) ?? "",
            kind: kind, scope: .shared, source: source, category: nil, currency: currency
        )
        transaction.cloudID = cloudID
        transaction.authorID = (record["authorID"] as? String) ?? ""
        transaction.ckSystemFields = systemFields(from: record)
        return transaction
    }

    static func apply(_ record: CKRecord, to transaction: Transaction) {
        if let amount = decodeAmount(record["amount"] as? String) { transaction.amount = amount }
        if let currency = record["currency"] as? String { transaction.currency = currency }
        if let date = record["date"] as? Date { transaction.date = date }
        if let merchant = record["merchant"] as? String { transaction.merchant = merchant }
        if let note = record["note"] as? String { transaction.note = note }
        if let kindRaw = record["kind"] as? String, let kind = TransactionKind(rawValue: kindRaw) { transaction.kind = kind }
        if let sourceRaw = record["source"] as? String, let source = EntrySource(rawValue: sourceRaw) { transaction.source = source }
        if let authorID = record["authorID"] as? String { transaction.authorID = authorID }
        transaction.ckSystemFields = systemFields(from: record)
    }

    /// Last-write-wins by modification date; a tie (two devices saving in the
    /// same instant) breaks on the record name so the outcome is
    /// deterministic instead of depending on whose clock is a millisecond
    /// ahead.
    /// ponytail: last-write-wins per record; upgrade to field-level merge if
    /// partners report clobbered edits in practice.
    static func isNewer(_ candidate: CKRecord, than incumbent: CKRecord) -> Bool {
        let a = candidate.modificationDate ?? .distantPast
        let b = incumbent.modificationDate ?? .distantPast
        if a != b { return a > b }
        return candidate.recordID.recordName > incumbent.recordID.recordName
    }

    /// A record that was previously synced and has since flipped back to
    /// personal must be pulled off CloudKit, not merely stop being pushed.
    /// No "previous scope" bookkeeping needed — having cached system fields
    /// is itself the signal that the record is currently live on CloudKit.
    static func shouldDeleteRemote(hadSystemFields: Bool, scope: Scope) -> Bool {
        hadSystemFields && scope == .personal
    }

    /// The mirror image: shared, and never yet on CloudKit.
    static func needsInitialUpload(hadSystemFields: Bool, scope: Scope) -> Bool {
        !hadSystemFields && scope == .shared
    }

    /// Only losing or swapping the account invalidates the share's tokens.
    static func forgetsShare(after change: CKSyncEngine.Event.AccountChange.ChangeType) -> Bool {
        switch change {
        case .signIn: return false
        case .signOut, .switchAccounts: return true
        @unknown default: return true
        }
    }

    // MARK: Budget

    static func record(from budget: Budget, zoneID: CKRecordZone.ID, calendar: Calendar = .current) -> CKRecord {
        let name = budgetRecordName(monthStart: budget.monthStart, currency: budget.currency ?? Money.code, calendar: calendar)
        let record = existingOrNewRecord(systemFields: budget.ckSystemFields, recordName: name, type: budgetRecordType, zoneID: zoneID)
        record["monthStart"] = budget.monthStart as CKRecordValue
        record["currency"] = (budget.currency ?? Money.code) as CKRecordValue
        record["total"] = encode(budget.total) as CKRecordValue
        record["family"] = (budget.familyJSON ?? "") as CKRecordValue
        record["limits"] = encodeLimits(budget.limits) as CKRecordValue
        return record
    }

    /// Per-category limits ride along as one JSON blob keyed by category name —
    /// same reasoning as the transaction's denormalized category.
    static func encodeLimits(_ limits: [BudgetLimit]) -> String {
        var map: [String: String] = [:]
        for limit in limits {
            guard let name = limit.category?.name, !name.isEmpty else { continue }
            map[name] = encode(limit.amount)
        }
        return (try? JSONEncoder().encode(map)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decodeLimits(_ json: String?) -> [String: Decimal] {
        guard let json, let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return raw.compactMapValues { Decimal(string: $0) }
    }

    // MARK: Settlement

    static func record(from settlement: Settlement, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = existingOrNewRecord(
            systemFields: settlement.ckSystemFields,
            recordName: settlementRecordName(settlement.cloudID),
            type: settlementRecordType,
            zoneID: zoneID
        )
        record["amount"] = encode(settlement.amount) as CKRecordValue
        record["currency"] = settlement.currency as CKRecordValue
        record["date"] = settlement.date as CKRecordValue
        record["fromMemberID"] = settlement.fromMemberID as CKRecordValue
        record["toMemberID"] = settlement.toMemberID as CKRecordValue
        return record
    }

    static func makeSettlement(from record: CKRecord) -> Settlement? {
        guard let name = record.recordID.recordName.split(separator: "-", maxSplits: 1).last.map(String.init),
              let cloudID = UUID(uuidString: name),
              let amount = decodeAmount(record["amount"] as? String),
              let currency = record["currency"] as? String,
              let date = record["date"] as? Date
        else { return nil }
        let settlement = Settlement(
            amount: amount, currency: currency, date: date,
            fromMemberID: (record["fromMemberID"] as? String) ?? "",
            toMemberID: (record["toMemberID"] as? String) ?? ""
        )
        settlement.cloudID = cloudID
        settlement.ckSystemFields = systemFields(from: record)
        return settlement
    }

    static func apply(_ record: CKRecord, to settlement: Settlement) {
        if let amount = decodeAmount(record["amount"] as? String) { settlement.amount = amount }
        if let currency = record["currency"] as? String { settlement.currency = currency }
        if let date = record["date"] as? Date { settlement.date = date }
        if let from = record["fromMemberID"] as? String { settlement.fromMemberID = from }
        if let to = record["toMemberID"] as? String { settlement.toMemberID = to }
        settlement.ckSystemFields = systemFields(from: record)
    }

    // MARK: Goal, Subscription, Account, Transfer
    //
    // Same shape as Settlement: a prefixed record name, `make…` checks the
    // fields a row cannot exist without, `apply` copies the rest. Optional
    // dates are written as nil when unset, so "no deadline" travels too.

    static let goalRecordType = "Goal"
    static let subscriptionRecordType = "Subscription"
    static let accountRecordType = "Account"
    static let transferRecordType = "Transfer"

    static func recordName(prefix: String, _ id: UUID) -> String { prefix + "-" + id.uuidString }

    /// The UUID inside a prefixed record name, or nil when the prefix differs.
    static func uuid(in recordName: String, prefix: String) -> UUID? {
        guard recordName.hasPrefix(prefix + "-") else { return nil }
        return UUID(uuidString: String(recordName.dropFirst(prefix.count + 1)))
    }

    /// Accounts first, so a transaction, subscription or transfer in the same
    /// fetch can find the account it points at.
    static func applyOrder(_ recordType: String) -> Int { recordType == accountRecordType ? 0 : 1 }

    /// Indices of every repeat of an id already seen earlier in `ids`. A
    /// default-valued UUID column can be backfilled with one value on every
    /// existing row by a lightweight migration; uploaded as-is, those rows
    /// would collapse into a single CloudKit record.
    static func duplicateIndices(_ ids: [UUID]) -> [Int] {
        var seen = Set<UUID>()
        return ids.indices.filter { !seen.insert(ids[$0]).inserted }
    }

    static func record(from goal: Goal, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = existingOrNewRecord(systemFields: goal.ckSystemFields, recordName: recordName(prefix: "goal", goal.cloudID), type: goalRecordType, zoneID: zoneID)
        record["name"] = goal.name as CKRecordValue
        record["symbol"] = goal.symbol as CKRecordValue
        record["tint"] = goal.tintHex as CKRecordValue
        record["target"] = encode(goal.target) as CKRecordValue
        record["saved"] = encode(goal.saved) as CKRecordValue
        record["deadline"] = goal.deadline.map { $0 as CKRecordValue }
        record["createdAt"] = goal.createdAt as CKRecordValue
        return record
    }

    static func makeGoal(from record: CKRecord) -> Goal? {
        guard let cloudID = uuid(in: record.recordID.recordName, prefix: "goal"),
              decodeAmount(record["target"] as? String) != nil else { return nil }
        let goal = Goal(name: "", symbol: "flag", tintHex: "7A5B86", target: 0, scope: .shared)
        goal.cloudID = cloudID
        apply(record, to: goal)
        return goal
    }

    static func apply(_ record: CKRecord, to goal: Goal) {
        if let name = record["name"] as? String { goal.name = name }
        if let symbol = record["symbol"] as? String { goal.symbol = symbol }
        if let tint = record["tint"] as? String { goal.tintHex = tint }
        if let target = decodeAmount(record["target"] as? String) { goal.target = target }
        if let saved = decodeAmount(record["saved"] as? String) { goal.saved = saved }
        goal.deadline = record["deadline"] as? Date
        if let createdAt = record["createdAt"] as? Date { goal.createdAt = createdAt }
        goal.scope = .shared
        goal.ckSystemFields = systemFields(from: record)
    }

    /// Reminder days and the payments ledger stay on each phone: a reminder is
    /// a personal preference, and only the author's phone records charges.
    static func record(from subscription: Subscription, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = existingOrNewRecord(systemFields: subscription.ckSystemFields, recordName: recordName(prefix: "subscription", subscription.id), type: subscriptionRecordType, zoneID: zoneID)
        record["name"] = subscription.name as CKRecordValue
        record["amount"] = encode(subscription.amount) as CKRecordValue
        record["currency"] = subscription.currency as CKRecordValue
        record["frequency"] = subscription.frequency.rawValue as CKRecordValue
        record["nextPaymentDate"] = subscription.nextPaymentDate as CKRecordValue
        record["anchorDay"] = subscription.anchorDay as CKRecordValue
        record["endDate"] = subscription.endDate.map { $0 as CKRecordValue }
        record["trialEndsAt"] = subscription.trialEndsAt.map { $0 as CKRecordValue }
        record["paymentMode"] = subscription.paymentMode.rawValue as CKRecordValue
        record["status"] = subscription.status.rawValue as CKRecordValue
        record["note"] = subscription.note as CKRecordValue
        record["kind"] = subscription.kind.rawValue as CKRecordValue
        record["createdAt"] = subscription.createdAt as CKRecordValue
        record["authorID"] = subscription.authorID as CKRecordValue
        record["accountID"] = sharedAccountID(subscription.account) as CKRecordValue
        writeCategory(subscription.category, to: record)
        return record
    }

    static func makeSubscription(from record: CKRecord) -> Subscription? {
        guard let id = uuid(in: record.recordID.recordName, prefix: "subscription"),
              let amount = decodeAmount(record["amount"] as? String),
              let next = record["nextPaymentDate"] as? Date else { return nil }
        let subscription = Subscription(name: "", amount: amount, nextPaymentDate: next, scope: .shared, category: nil)
        subscription.id = id
        apply(record, to: subscription)
        return subscription
    }

    static func apply(_ record: CKRecord, to subscription: Subscription) {
        if let name = record["name"] as? String { subscription.name = name }
        if let amount = decodeAmount(record["amount"] as? String) { subscription.amount = amount }
        if let currency = record["currency"] as? String { subscription.currency = currency }
        if let raw = record["frequency"] as? String, let frequency = BillingFrequency(rawValue: raw) { subscription.frequency = frequency }
        if let next = record["nextPaymentDate"] as? Date { subscription.nextPaymentDate = next }
        if let anchorDay = record["anchorDay"] as? Int { subscription.anchorDay = anchorDay }
        subscription.endDate = record["endDate"] as? Date
        subscription.trialEndsAt = record["trialEndsAt"] as? Date
        if let raw = record["paymentMode"] as? String, let mode = PaymentMode(rawValue: raw) { subscription.paymentMode = mode }
        if let raw = record["status"] as? String, let status = SubscriptionStatus(rawValue: raw) { subscription.status = status }
        if let note = record["note"] as? String { subscription.note = note }
        if let raw = record["kind"] as? String, let kind = TransactionKind(rawValue: raw) { subscription.kind = kind }
        if let createdAt = record["createdAt"] as? Date { subscription.createdAt = createdAt }
        if let authorID = record["authorID"] as? String { subscription.authorID = authorID }
        subscription.scope = .shared
        subscription.ckSystemFields = systemFields(from: record)
    }

    /// Sort order stays local: each phone arranges its own account list.
    static func record(from account: Account, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = existingOrNewRecord(systemFields: account.ckSystemFields, recordName: recordName(prefix: "account", account.cloudID), type: accountRecordType, zoneID: zoneID)
        record["name"] = account.name as CKRecordValue
        record["kind"] = account.kind.rawValue as CKRecordValue
        record["tint"] = account.tintHex as CKRecordValue
        record["currency"] = account.currency as CKRecordValue
        record["openingBalance"] = encode(account.openingBalance) as CKRecordValue
        record["isArchived"] = account.isArchived as CKRecordValue
        record["createdAt"] = account.createdAt as CKRecordValue
        return record
    }

    static func makeAccount(from record: CKRecord) -> Account? {
        guard let cloudID = uuid(in: record.recordID.recordName, prefix: "account"),
              let currency = record["currency"] as? String else { return nil }
        let account = Account(name: "", currency: currency)
        account.cloudID = cloudID
        apply(record, to: account)
        return account
    }

    static func apply(_ record: CKRecord, to account: Account) {
        if let name = record["name"] as? String { account.name = name }
        if let raw = record["kind"] as? String, let kind = AccountKind(rawValue: raw) { account.kind = kind }
        if let tint = record["tint"] as? String { account.tintHex = tint }
        if let currency = record["currency"] as? String { account.currency = currency }
        if let opening = decodeAmount(record["openingBalance"] as? String) { account.openingBalance = opening }
        if let archived = record["isArchived"] as? Bool { account.isArchived = archived }
        if let createdAt = record["createdAt"] as? Date { account.createdAt = createdAt }
        account.scope = .shared
        account.ckSystemFields = systemFields(from: record)
    }

    /// A move into or out of a shared account changes that account's balance,
    /// so it travels — but only with the shared side's id. The partner sees
    /// money arrive from (or leave to) "no account", never the personal one.
    static func isShared(_ transfer: Transfer) -> Bool {
        transfer.from?.scope == .shared || transfer.to?.scope == .shared
    }

    static func record(from transfer: Transfer, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = existingOrNewRecord(systemFields: transfer.ckSystemFields, recordName: recordName(prefix: "transfer", transfer.cloudID), type: transferRecordType, zoneID: zoneID)
        record["amount"] = encode(transfer.amount) as CKRecordValue
        record["currency"] = transfer.currency as CKRecordValue
        record["date"] = transfer.date as CKRecordValue
        record["note"] = transfer.note as CKRecordValue
        record["fromID"] = sharedAccountID(transfer.from) as CKRecordValue
        record["toID"] = sharedAccountID(transfer.to) as CKRecordValue
        return record
    }

    /// Accounts are resolved by the engine, which can look them up.
    static func makeTransfer(from record: CKRecord) -> Transfer? {
        guard let cloudID = uuid(in: record.recordID.recordName, prefix: "transfer"),
              let amount = decodeAmount(record["amount"] as? String),
              let currency = record["currency"] as? String,
              let date = record["date"] as? Date else { return nil }
        let transfer = Transfer(amount: amount, currency: currency, date: date, from: nil, to: nil)
        transfer.cloudID = cloudID
        apply(record, to: transfer)
        return transfer
    }

    static func apply(_ record: CKRecord, to transfer: Transfer) {
        if let amount = decodeAmount(record["amount"] as? String) { transfer.amount = amount }
        if let currency = record["currency"] as? String { transfer.currency = currency }
        if let date = record["date"] as? Date { transfer.date = date }
        if let note = record["note"] as? String { transfer.note = note }
        transfer.ckSystemFields = systemFields(from: record)
    }
}

/// What the engine needs from every synced model: where it lives on CloudKit,
/// whether it belongs there right now, and its cached change tag.
protocol FamilySynced: PersistentModel {
    var familyRecordName: String { get }
    var isFamilyShared: Bool { get }
    var ckSystemFields: Data? { get set }
}

extension Transaction: FamilySynced {
    var familyRecordName: String { cloudID.uuidString }
    var isFamilyShared: Bool { scope == .shared }
}

extension Budget: FamilySynced {
    var familyRecordName: String { FamilySync.budgetRecordName(monthStart: monthStart, currency: currency ?? Money.code) }
    var isFamilyShared: Bool { scope == .shared }
}

extension Settlement: FamilySynced {
    var familyRecordName: String { FamilySync.settlementRecordName(cloudID) }
    var isFamilyShared: Bool { true }
}

extension Goal: FamilySynced {
    var familyRecordName: String { FamilySync.recordName(prefix: "goal", cloudID) }
    var isFamilyShared: Bool { scope == .shared }
}

extension Subscription: FamilySynced {
    var familyRecordName: String { FamilySync.recordName(prefix: "subscription", id) }
    var isFamilyShared: Bool { scope == .shared }
}

extension Account: FamilySynced {
    var familyRecordName: String { FamilySync.recordName(prefix: "account", cloudID) }
    var isFamilyShared: Bool { scope == .shared }
}

extension Transfer: FamilySynced {
    var familyRecordName: String { FamilySync.recordName(prefix: "transfer", cloudID) }
    var isFamilyShared: Bool { FamilySync.isShared(self) }
}

/// Turning a `Transaction.authorID` into something a person can read.
enum FamilyMembers {
    static func displayName(for authorID: String, in members: [FamilyMember], fallback: String = "Partner") -> String {
        if authorID.isEmpty { return members.first { $0.isMe }?.name ?? "You" }
        if let match = members.first(where: { $0.memberID == authorID }) { return match.name }
        return fallback
    }

    /// Two initials at most — what the contribution rows show as an avatar.
    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    /// Everyone who could owe or be owed: the people on the share, plus anyone
    /// who already authored a shared transaction.
    static func ids(members: [FamilyMember], transactions: [Transaction], meID: String) -> [String] {
        var ids = Set(members.map(\.memberID))
        for transaction in transactions where transaction.scope == .shared {
            ids.insert(transaction.authorID.isEmpty ? meID : transaction.authorID)
        }
        ids.insert(meID)
        return ids.filter { !$0.isEmpty }.sorted()
    }
}

/// The one stateful class this feature needs. `CKSyncEngineDelegate` requires
/// reference identity and callbacks over time, unlike every other enum in
/// this codebase's business-logic layer (Budgeting, Subscriptions,
/// CategoryClassifier).
@MainActor
final class FamilySyncEngine: NSObject {
    static let shared = FamilySyncEngine()

    private static let roleKey = "familySync.role"
    private static let ownerNameKey = "familySync.ownerName"
    /// Per role: an owner's engine state means nothing to a participant's
    /// engine, and restoring the wrong one resurrects tokens for a zone this
    /// device cannot reach.
    private static func stateKey(_ role: FamilyRole) -> String { "familySync.engineState.\(role.rawValue)" }

    private var syncEngine: CKSyncEngine?
    private var context: ModelContext?
    private var zoneID: CKRecordZone.ID?
    private var role: FamilyRole?
    private var saveObserver: NSObjectProtocol?
    private var deleteObserver: NSObjectProtocol?
    /// Rows the engine itself just wrote (fetched changes, fresh change tags).
    /// Their save notification is not a user edit: re-uploading them echoed
    /// every synced record back and forth between the two phones forever.
    private var engineWrites: Set<PersistentIdentifier> = []
    /// Records the partner deleted, so applying that deletion locally isn't
    /// sent straight back to CloudKit as a delete of our own.
    private var remoteDeletions: Set<CKRecord.ID> = []

    private var storedRole: FamilyRole? {
        UserDefaults.standard.string(forKey: Self.roleKey).flatMap(FamilyRole.init(rawValue:))
    }
    private var storedOwnerName: String? { UserDefaults.standard.string(forKey: Self.ownerNameKey) }

    /// Names by member id, kept in memory so a transaction row can label its
    /// author without every row running its own fetch.
    private(set) var memberNames: [String: String] = [:]

    func memberName(for authorID: String) -> String? {
        authorID.isEmpty ? nil : memberNames[authorID]
    }

    private static let meIDKey = "familySync.meID"
    /// This device's CloudKit user record name, cached so views and save
    /// stamping never have to await a network call. Empty until the first
    /// successful lookup, which every reader already treats as "me".
    private(set) var meID: String = UserDefaults.standard.string(forKey: FamilySyncEngine.meIDKey) ?? ""

    private override init() { super.init() }

    /// Called once from `MonevaApp.init()`. A no-op until a share exists —
    /// true for most launches, most users.
    func catchUp(in context: ModelContext) {
        self.context = context
        repairDuplicateIDs(in: context)
        guard let role = storedRole else { return }
        for member in (try? context.fetch(FetchDescriptor<FamilyMember>())) ?? [] {
            memberNames[member.memberID] = member.name
        }
        FamilySyncStatus.shared.role = role
        start(role: role, ownerName: storedOwnerName)
    }

    /// Called by `SceneDelegate` when this device opens the partner's invite.
    /// Opening your own invite link is not joining anything.
    func accept(_ metadata: CKShare.Metadata) {
        guard metadata.participantRole != .owner else { return }
        let container = CKContainer(identifier: metadata.containerIdentifier)
        // The zone stays owned by whoever sent the invite; this device reaches
        // it through the shared database under that owner's name.
        let ownerName = metadata.share.recordID.zoneID.ownerName
        Task {
            do {
                try await container.accept(metadata)
                acceptedShare(role: .participant, ownerName: ownerName)
            } catch {
                FamilySyncStatus.shared.lastError = error.localizedDescription
            }
        }
    }

    /// Called by `accept(_:)` once this device has joined the partner's
    /// share, and by `makeOrFetchShare()` once this device owns one.
    func acceptedShare(role: FamilyRole, ownerName: String?) {
        // Switching sides (an owner joining someone else's share) must drop
        // the old engine, or `start` keeps syncing the old zone until relaunch.
        if syncEngine != nil, self.role != role { forgetShare() }
        UserDefaults.standard.set(role.rawValue, forKey: Self.roleKey)
        UserDefaults.standard.set(ownerName, forKey: Self.ownerNameKey)
        FamilySyncStatus.shared.role = role
        FamilySyncStatus.shared.lastError = nil
        start(role: role, ownerName: ownerName)
    }

    /// Leaving the family stops syncing but never deletes anything local —
    /// the records stay `shared`-scope, they just stop travelling.
    func stopSharing() {
        forgetShare()
    }

    private func forgetShare() {
        syncEngine = nil
        zoneID = nil
        if let role { UserDefaults.standard.removeObject(forKey: Self.stateKey(role)) }
        role = nil
        UserDefaults.standard.removeObject(forKey: Self.roleKey)
        UserDefaults.standard.removeObject(forKey: Self.ownerNameKey)
        FamilySyncStatus.shared.role = nil
        FamilySyncStatus.shared.lastSyncedAt = nil
    }

    /// Creates the zone-wide share on first use, or returns the existing one.
    /// Not a pure function — it talks to CloudKit — so it lives here, not in
    /// `FamilySync`.
    func makeOrFetchShare() async throws -> CKShare {
        let db = CKContainer.default().privateCloudDatabase
        let zoneID = FamilySync.zoneID()
        if (try? await db.recordZone(for: zoneID)) == nil {
            _ = try await db.save(CKRecordZone(zoneID: zoneID))
        }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        let share: CKShare
        if let existing = try? await db.record(for: shareID) as? CKShare {
            share = existing
        } else {
            share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = "Ledgea family budget" as CKRecordValue
            _ = try await db.save(share)
        }
        // Also on the existing-share path: after a reinstall or a forgotten
        // role the share is still on CloudKit, and this is what restarts sync.
        acceptedShare(role: .owner, ownerName: CKCurrentUserDefaultName)
        return share
    }

    private func start(role: FamilyRole, ownerName: String?) {
        guard syncEngine == nil, let context else { return }
        self.role = role
        let zoneID = FamilySync.zoneID(role: role, ownerName: ownerName)
        self.zoneID = zoneID
        let state = UserDefaults.standard.data(forKey: Self.stateKey(role)).flatMap {
            try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        // A participant never owns the family zone: their copy of it is reached
        // through the shared database, under the owner's name.
        let container = CKContainer.default()
        let config = CKSyncEngine.Configuration(
            database: role == .owner ? container.privateCloudDatabase : container.sharedCloudDatabase,
            stateSerialization: state,
            delegate: self
        )
        syncEngine = CKSyncEngine(config)
        observeSaves(in: context)
        Task {
            await resolveIdentity(role: role, ownerName: ownerName)
            // After identity, so the backlog is stamped with a real author.
            enqueueUnsynced()
        }
    }

    /// Shared records saved before the share existed never passed through
    /// `handleSave`, so without this the partner only ever sees what was
    /// added after the invite. The engine deduplicates pending changes, so
    /// running it on every start is harmless.
    private func enqueueUnsynced() {
        guard let syncEngine, let zoneID, let context else { return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        func collect<T: FamilySynced>(_ type: T.Type) {
            for model in (try? context.fetch(FetchDescriptor<T>())) ?? []
            where FamilySync.needsInitialUpload(hadSystemFields: model.ckSystemFields != nil, scope: model.isFamilyShared ? .shared : .personal) {
                stampAuthor(model)
                changes.append(.saveRecord(CKRecord.ID(recordName: model.familyRecordName, zoneID: zoneID)))
            }
        }
        collect(Account.self)
        collect(Transaction.self)
        collect(Budget.self)
        collect(Settlement.self)
        collect(Goal.self)
        collect(Subscription.self)
        collect(Transfer.self)
        if !changes.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: changes) }
    }

    /// Stamped once, here and in `handleSave`, rather than at every save site
    /// that can create a shared transaction or subscription.
    private func stampAuthor(_ model: any FamilySynced) {
        if let transaction = model as? Transaction, transaction.authorID.isEmpty { transaction.authorID = meID }
        if let subscription = model as? Subscription, subscription.authorID.isEmpty { subscription.authorID = meID }
    }

    /// See `FamilySync.duplicateIndices`. Rows already on CloudKit sort first,
    /// so the copy the partner already has keeps its id. Runs every launch,
    /// before any sync starts — cheap, and harmless once the ids are unique.
    private func repairDuplicateIDs(in context: ModelContext) {
        func repair<T: FamilySynced>(_ type: T.Type, _ id: ReferenceWritableKeyPath<T, UUID>) {
            let rows = ((try? context.fetch(FetchDescriptor<T>())) ?? [])
                .sorted { $0.ckSystemFields != nil && $1.ckSystemFields == nil }
            for index in FamilySync.duplicateIndices(rows.map { $0[keyPath: id] }) where rows[index].ckSystemFields == nil {
                rows[index][keyPath: id] = UUID()
            }
        }
        repair(Transaction.self, \.cloudID)
        repair(Goal.self, \.cloudID)
        repair(Account.self, \.cloudID)
        repair(Transfer.self, \.cloudID)
        if context.hasChanges { try? context.save() }
    }

    /// Who I am on CloudKit, and who else is on this share. Both are cached
    /// locally: a name in a transaction row must not wait on the network.
    private func resolveIdentity(role: FamilyRole, ownerName: String?) async {
        let container = CKContainer.default()
        if let id = try? await container.userRecordID() {
            meID = id.recordName
            UserDefaults.standard.set(meID, forKey: Self.meIDKey)
        }
        let db = role == .owner ? container.privateCloudDatabase : container.sharedCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: FamilySync.zoneID(role: role, ownerName: ownerName))
        guard let share = try? await db.record(for: shareID) as? CKShare else { return }
        cacheMembers(of: share)
    }

    private func cacheMembers(of share: CKShare) {
        guard let context else { return }
        let existing = (try? context.fetch(FetchDescriptor<FamilyMember>())) ?? []
        for participant in share.participants {
            guard let id = participant.userIdentity.userRecordID?.recordName else { continue }
            let components = participant.userIdentity.nameComponents
            let name = components.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? participant.userIdentity.lookupInfo?.emailAddress
                ?? (id == meID ? "You" : "Partner")
            memberNames[id] = name
            if let member = existing.first(where: { $0.memberID == id }) {
                member.name = name
                member.isMe = id == meID
            } else {
                context.insert(FamilyMember(memberID: id, name: name, isMe: id == meID))
            }
        }
        try? context.save()
    }

    /// Root-cause fix: one observer on the model context's save notification,
    /// not a "mark dirty" call scattered across every existing save site
    /// that touches a shared-scope Transaction.
    private func observeSaves(in context: ModelContext) {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: .main) { [weak self] note in
            // Pull the (Sendable) identifiers out here, in the notification's
            // own non-isolated closure, so the hop to the actor never has to
            // carry the non-Sendable `Notification` across it.
            guard let userInfo = note.userInfo else { return }
            let inserted = userInfo[ModelContext.NotificationKey.insertedIdentifiers] as? Set<PersistentIdentifier> ?? []
            let updated = userInfo[ModelContext.NotificationKey.updatedIdentifiers] as? Set<PersistentIdentifier> ?? []
            let changed = inserted.union(updated)
            guard !changed.isEmpty, let self else { return }
            Task { @MainActor in self.handleSave(changed) }
        }
        // Deletions need the rows' record names, which are gone once the save
        // lands — so read them synchronously in `willSave` (queue: nil runs
        // this on the saving thread, the main one for the main context).
        deleteObserver = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueDeletions() }
        }
    }

    private func handleSave(_ changed: Set<PersistentIdentifier>) {
        guard let syncEngine, let zoneID, let context else { return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        func queue(_ model: any FamilySynced) {
            let recordID = CKRecord.ID(recordName: model.familyRecordName, zoneID: zoneID)
            if FamilySync.shouldDeleteRemote(hadSystemFields: model.ckSystemFields != nil, scope: model.isFamilyShared ? .shared : .personal) {
                changes.append(.deleteRecord(recordID))
                model.ckSystemFields = nil
            } else if model.isFamilyShared {
                stampAuthor(model)
                changes.append(.saveRecord(recordID))
            }
        }
        for id in changed where engineWrites.remove(id) == nil {
            guard let model = context.model(for: id) as? any FamilySynced else { continue }
            queue(model)
            // An account switching sides changes what its links may carry:
            // transfers start or stop travelling, and shared transactions gain
            // or lose its id.
            if let account = model as? Account {
                for transfer in transfers(touching: account) { queue(transfer) }
                for transaction in account.transactions where transaction.scope == .shared { queue(transaction) }
            }
        }
        if !changes.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: changes) }
    }

    private func queueDeletions() {
        guard let syncEngine, let zoneID, let context else { return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        for case let model as any FamilySynced in context.deletedModelsArray where model.ckSystemFields != nil {
            let recordID = CKRecord.ID(recordName: model.familyRecordName, zoneID: zoneID)
            if remoteDeletions.remove(recordID) != nil { continue }
            changes.append(.deleteRecord(recordID))
        }
        if !changes.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: changes) }
    }

    /// Saves what the engine itself just wrote and remembers those rows, so
    /// their save notification isn't mistaken for a user edit.
    /// ponytail: a user edit to the same row landing in this very save is
    /// skipped once; the row's next edit syncs it.
    private func saveEngineWrites() {
        guard let context else { return }
        let touched = context.insertedModelsArray + context.changedModelsArray
        try? context.save()
        // Read after the save: inserted rows only get their permanent ids then.
        engineWrites.formUnion(touched.map(\.persistentModelID))
    }

    private func transfers(touching account: Account) -> [Transfer] {
        guard let context else { return [] }
        let id = account.persistentModelID
        return ((try? context.fetch(FetchDescriptor<Transfer>())) ?? [])
            .filter { $0.from?.persistentModelID == id || $0.to?.persistentModelID == id }
    }

    /// The local row a record name points at, whatever its type.
    private func model(named name: String) -> (any FamilySynced)? {
        guard let context else { return nil }
        if name.hasPrefix("budget-") { return budget(recordName: name) }
        if name.hasPrefix("settlement-") { return settlement(recordName: name) }
        if let id = FamilySync.uuid(in: name, prefix: "goal") {
            return try? context.fetch(FetchDescriptor<Goal>(predicate: #Predicate { $0.cloudID == id })).first
        }
        if let id = FamilySync.uuid(in: name, prefix: "subscription") {
            return try? context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == id })).first
        }
        if let id = FamilySync.uuid(in: name, prefix: "account") { return account(cloudID: id) }
        if let id = FamilySync.uuid(in: name, prefix: "transfer") {
            return try? context.fetch(FetchDescriptor<Transfer>(predicate: #Predicate { $0.cloudID == id })).first
        }
        return transaction(cloudID: name)
    }

    private func account(cloudID id: UUID) -> Account? {
        try? context?.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.cloudID == id })).first
    }

    /// A synced link to a shared account replaces the local one. No link
    /// clears only a shared account (the partner unlinked it), never a
    /// personal account this phone picked for itself. An account that hasn't
    /// arrived yet leaves the link as it was.
    private func resolvedAccount(_ id: UUID?, current: Account?) -> Account? {
        guard let id else { return current?.scope == .shared ? nil : current }
        return account(cloudID: id) ?? current
    }

    private func record(for model: any FamilySynced, zoneID: CKRecordZone.ID) -> CKRecord? {
        switch model {
        case let transaction as Transaction: return FamilySync.record(from: transaction, zoneID: zoneID)
        case let budget as Budget: return FamilySync.record(from: budget, zoneID: zoneID)
        case let settlement as Settlement: return FamilySync.record(from: settlement, zoneID: zoneID)
        case let goal as Goal: return FamilySync.record(from: goal, zoneID: zoneID)
        case let subscription as Subscription: return FamilySync.record(from: subscription, zoneID: zoneID)
        case let account as Account: return FamilySync.record(from: account, zoneID: zoneID)
        case let transfer as Transfer: return FamilySync.record(from: transfer, zoneID: zoneID)
        default: return nil
        }
    }

    /// One fetched record into the local store, matched by record name.
    private func applyFetched(_ record: CKRecord) {
        guard let context else { return }
        let existing = model(named: record.recordID.recordName)
        switch record.recordType {
        case FamilySync.budgetRecordType:
            applyBudget(record)
        case FamilySync.settlementRecordType:
            if let settlement = existing as? Settlement { FamilySync.apply(record, to: settlement) }
            else if let created = FamilySync.makeSettlement(from: record) { context.insert(created) }
        case FamilySync.goalRecordType:
            if let goal = existing as? Goal { FamilySync.apply(record, to: goal) }
            else if let created = FamilySync.makeGoal(from: record) { context.insert(created) }
        case FamilySync.accountRecordType:
            if let account = existing as? Account { FamilySync.apply(record, to: account) }
            else if let created = FamilySync.makeAccount(from: record) {
                created.sortIndex = Accounts.nextSortIndex((try? context.fetch(FetchDescriptor<Account>())) ?? [])
                context.insert(created)
            }
        case FamilySync.subscriptionRecordType:
            let target = existing as? Subscription ?? FamilySync.makeSubscription(from: record).map { context.insert($0); return $0 }
            guard let target else { return }
            if existing != nil { FamilySync.apply(record, to: target) }
            if let descriptor = FamilySync.categoryDescriptor(from: record, kind: target.kind) { target.category = category(for: descriptor) }
            target.account = resolvedAccount(FamilySync.accountID(in: record), current: target.account)
        case FamilySync.transferRecordType:
            let target = existing as? Transfer ?? FamilySync.makeTransfer(from: record).map { context.insert($0); return $0 }
            guard let target else { return }
            if existing != nil { FamilySync.apply(record, to: target) }
            target.from = resolvedAccount(FamilySync.accountID(in: record, key: "fromID"), current: target.from)
            target.to = resolvedAccount(FamilySync.accountID(in: record, key: "toID"), current: target.to)
        default:
            guard let cloudID = UUID(uuidString: record.recordID.recordName) else { return }
            let target = existing as? Transaction ?? FamilySync.makeTransaction(from: record, cloudID: cloudID).map { context.insert($0); return $0 }
            guard let target else { return }
            if existing != nil { FamilySync.apply(record, to: target) }
            if let descriptor = FamilySync.categoryDescriptor(from: record, kind: target.kind) { target.category = category(for: descriptor) }
            target.account = resolvedAccount(FamilySync.accountID(in: record), current: target.account)
        }
    }

    private func transaction(cloudID: String) -> Transaction? {
        guard let context, let uuid = UUID(uuidString: cloudID) else { return nil }
        let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate { $0.cloudID == uuid })
        return try? context.fetch(descriptor).first
    }

    private func settlement(recordName: String) -> Settlement? {
        guard let context,
              let raw = recordName.split(separator: "-", maxSplits: 1).last.map(String.init),
              let uuid = UUID(uuidString: raw) else { return nil }
        let descriptor = FetchDescriptor<Settlement>(predicate: #Predicate { $0.cloudID == uuid })
        return try? context.fetch(descriptor).first
    }

    private func budget(recordName: String) -> Budget? {
        guard let context else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        return all.first {
            $0.scope == .shared
                && FamilySync.budgetRecordName(monthStart: $0.monthStart, currency: $0.currency ?? Money.code) == recordName
        }
    }

    /// The one place a synced-in category name becomes a real
    /// `SpendingCategory`: matched against the shared list, created only when
    /// nothing matches.
    private func category(for descriptor: FamilySync.CategoryDescriptor) -> SpendingCategory? {
        guard let context else { return nil }
        let categories = (try? context.fetch(FetchDescriptor<SpendingCategory>())) ?? []
        if let match = FamilySync.matchCategory(descriptor, in: categories) { return match }
        let created = SpendingCategory(
            name: descriptor.name, symbol: descriptor.symbol,
            tintHex: descriptor.tintHex, softHex: descriptor.softHex,
            scope: .shared, kind: descriptor.kind,
            sortIndex: CategoryLibrary.nextSortIndex(in: categories, scope: .shared, kind: descriptor.kind)
        )
        context.insert(created)
        return created
    }

    private func applyBudget(_ record: CKRecord) {
        guard let context else { return }
        guard let monthStart = record["monthStart"] as? Date,
              let currency = record["currency"] as? String,
              let total = FamilySync.decodeAmount(record["total"] as? String) else { return }
        let budget = self.budget(recordName: record.recordID.recordName) ?? {
            let created = Budget(monthStart: monthStart, total: total, scope: .shared)
            created.currency = currency
            context.insert(created)
            return created
        }()
        budget.total = total
        budget.currency = currency
        budget.familyJSON = (record["family"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        budget.ckSystemFields = FamilySync.systemFields(from: record)

        // Same wholesale rebuild the budget editor does — limits are a set, not
        // a list with identity.
        let wanted = FamilySync.decodeLimits(record["limits"] as? String)
        for limit in budget.limits { context.delete(limit) }
        budget.limits = []
        let categories = (try? context.fetch(FetchDescriptor<SpendingCategory>())) ?? []
        for (name, amount) in wanted {
            let descriptor = FamilySync.CategoryDescriptor(name: name, symbol: "circle", tintHex: "78746A", softHex: "E4E2DB", kind: .expense)
            guard let category = FamilySync.matchCategory(descriptor, in: categories) ?? self.category(for: descriptor) else { continue }
            let limit = BudgetLimit(amount: amount, category: category)
            limit.budget = budget
            context.insert(limit)
        }
    }
}

extension FamilySyncEngine: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            guard let role else { return }
            let data = try? JSONEncoder().encode(update.stateSerialization)
            UserDefaults.standard.set(data, forKey: Self.stateKey(role))

        // Signing out of iCloud invalidates every token this engine holds;
        // keeping them would fetch against an account that is no longer here.
        // A sign-in is not that: a fresh engine reports one on its very first
        // run, and forgetting the share there killed every new share at birth.
        case .accountChange(let change):
            if FamilySync.forgetsShare(after: change.changeType) { forgetShare() }
            else { enqueueUnsynced() }

        case .fetchedRecordZoneChanges(let changes):
            guard let context else { return }
            let records = changes.modifications.map(\.record)
                .sorted { FamilySync.applyOrder($0.recordType) < FamilySync.applyOrder($1.recordType) }
            for record in records { applyFetched(record) }
            for deletion in changes.deletions {
                guard let existing = model(named: deletion.recordID.recordName) else { continue }
                remoteDeletions.insert(deletion.recordID)
                context.delete(existing)
            }
            saveEngineWrites()
            FamilySyncStatus.shared.lastSyncedAt = .now

        case .sentRecordZoneChanges(let sent):
            guard let zoneID else { return }
            for saved in sent.savedRecords {
                model(named: saved.recordID.recordName)?.ckSystemFields = FamilySync.systemFields(from: saved)
            }
            // Only the one failure CKSyncEngine leaves to the app; everything
            // else (throttling, network, expired tokens) is its own job.
            for failure in sent.failedRecordSaves where failure.error.code == .serverRecordChanged {
                guard let server = failure.error.serverRecord,
                      let existing = model(named: server.recordID.recordName),
                      let mine = record(for: existing, zoneID: zoneID) else { continue }
                if FamilySync.isNewer(mine, than: server) {
                    // Adopt the server's change tag *before* resending, or the
                    // retry carries the same stale tag and fails identically —
                    // a loop, not a merge.
                    existing.ckSystemFields = FamilySync.systemFields(from: server)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
                } else {
                    applyFetched(server)
                }
            }
            saveEngineWrites()

        default:
            break
        }
    }

    // ponytail: only one zone exists today, so every pending change belongs
    // to it — no need to filter by the batch's requested zone scope; revisit
    // if a second zone is ever added.
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges
        guard !pending.isEmpty, let zoneID else { return nil }
        // Resolved here, on the actor, so the record-provider closure below
        // never has to reach back across the actor boundary to `self`.
        let recordsByID: [CKRecord.ID: CKRecord] = pending.reduce(into: [:]) { result, change in
            // Re-checked at send time: a row queued while shared and flipped
            // to personal before this batch must not leave the device.
            guard case .saveRecord(let recordID) = change,
                  let model = model(named: recordID.recordName), model.isFamilyShared else { return }
            result[recordID] = record(for: model, zoneID: zoneID)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            recordsByID[recordID]
        }
    }
}

#if DEBUG
/// Pure-function coverage only — `CKSyncEngine` itself is async and network-
/// backed, so it cannot live in a synchronous assert block. The cross-account
/// invite→accept round-trip needs two physical devices on two different
/// Apple IDs; the Simulator can only hold one iCloud account.
func familySyncSelfCheck() {
    assert(FamilySync.decodeAmount(FamilySync.encode(Decimal(string: "42.50")!)) == Decimal(string: "42.50")!, "amount must round-trip exactly through the CKRecord string encoding")
    assert(FamilySync.decodeAmount(FamilySync.encode(Decimal(string: "9.99")!)) == Decimal(string: "9.99")!)
    assert(FamilySync.decodeAmount("not a number") == nil, "malformed CKRecord amount must not silently become zero")

    assert(!FamilySync.shouldDeleteRemote(hadSystemFields: false, scope: .personal), "never synced, stays personal: nothing to delete")
    assert(!FamilySync.shouldDeleteRemote(hadSystemFields: false, scope: .shared), "never synced yet, will be pushed, not deleted")
    assert(!FamilySync.shouldDeleteRemote(hadSystemFields: true, scope: .shared), "still shared: keep syncing")
    assert(FamilySync.shouldDeleteRemote(hadSystemFields: true, scope: .personal), "was synced, flipped to personal: must pull it off CloudKit")
    assert(FamilySync.needsInitialUpload(hadSystemFields: false, scope: .shared), "a shared record from before the invite must still reach the partner")
    assert(!FamilySync.needsInitialUpload(hadSystemFields: true, scope: .shared), "already on CloudKit: handleSave owns it")
    assert(!FamilySync.needsInitialUpload(hadSystemFields: false, scope: .personal), "personal never leaves the device")

    let me = CKRecord.ID(recordName: "me")
    assert(!FamilySync.forgetsShare(after: .signIn(currentUser: me)), "a fresh engine's first-run sign-in must not drop the share it was just started for")
    assert(FamilySync.forgetsShare(after: .signOut(previousUser: me)), "signing out invalidates the share's tokens")
    assert(FamilySync.forgetsShare(after: .switchAccounts(previousUser: me, currentUser: CKRecord.ID(recordName: "other"))), "another account must not reuse this one's share")

    // The bug that made Phase 1 unable to sync at all: a participant must
    // reach the owner's zone, not invent one of their own.
    assert(FamilySync.zoneID(role: .participant, ownerName: "partner").ownerName == "partner", "a participant syncs against the owner's zone")
    assert(FamilySync.zoneID(role: .owner, ownerName: "partner").ownerName == CKCurrentUserDefaultName, "the owner always syncs against their own zone")
    assert(FamilySync.zoneID(role: .participant, ownerName: nil).ownerName == CKCurrentUserDefaultName, "a participant with no remembered owner falls back rather than crashing")

    let shared = SpendingCategory(name: "Groceries", symbol: "cart", tintHex: "24544A", softHex: "E4E2DB", scope: .shared, kind: .expense)
    let personal = SpendingCategory(name: "Groceries", symbol: "cart", tintHex: "24544A", softHex: "E4E2DB", scope: .personal, kind: .expense)
    let income = SpendingCategory(name: "Groceries", symbol: "cart", tintHex: "24544A", softHex: "E4E2DB", scope: .shared, kind: .income)
    let wanted = FamilySync.CategoryDescriptor(name: "  groceries ", symbol: "cart", tintHex: "24544A", softHex: "E4E2DB", kind: .expense)
    assert(FamilySync.matchCategory(wanted, in: [personal, income, shared]) === shared, "a synced category matches by name, ignoring case and padding")
    assert(FamilySync.matchCategory(wanted, in: [personal, income]) == nil, "never borrow a personal or opposite-kind category for a shared transaction")

    var family = FamilyBudget()
    family.splitPercent = ["a": 60, "b": 40]
    family.allowance = ["a": "250.75"]
    let roundTripped = FamilyBudget.decode(family.encoded())
    assert(roundTripped == family, "the family side of a budget must survive the JSON column intact")
    assert(roundTripped.allowanceAmount(for: "a") == Decimal(string: "250.75")!, "an allowance is Decimal money, not a Double")
    assert(FamilyBudget().percent(for: "a", members: ["a", "b"]) == 50, "an unset split is an even one")
    assert(FamilyBudget().percent(for: "b", members: ["a", "b", "c"]) == 33, "an uneven member count still sums to 100")
    assert(FamilyBudget().percent(for: "a", members: ["a", "b", "c"]) == 34, "the remainder lands on the first member by sorted order, deterministically")

    let even = Budgeting.shares(of: Decimal(string: "10.01")!, currency: "AZN", split: FamilyBudget(), members: ["a", "b"], payer: "a")
    assert(even.values.reduce(Decimal.zero, +) == Decimal(string: "10.01")!, "the shares of an expense must add back up to it exactly")
    let tilted = Budgeting.shares(of: 100, currency: "AZN", split: family, members: ["a", "b"], payer: "a")
    assert(tilted["a"] == 60 && tilted["b"] == 40, "an explicit 60/40 split is honoured")

    assert(FamilyMembers.displayName(for: "", in: [FamilyMember(memberID: "me", name: "Ruslan", isMe: true)]) == "Ruslan", "an unstamped transaction is mine")
    assert(FamilyMembers.displayName(for: "ghost", in: []) == "Partner", "an unknown author still reads as a person")
    assert(FamilyMembers.initials("Ruslan Abdulov") == "RA")

    let zoneID = FamilySync.zoneID(ownerName: "test-owner")
    let older = CKRecord(recordType: FamilySync.transactionRecordType, recordID: CKRecord.ID(recordName: "aaaa", zoneID: zoneID))
    let newer = CKRecord(recordType: FamilySync.transactionRecordType, recordID: CKRecord.ID(recordName: "bbbb", zoneID: zoneID))
    assert(!FamilySync.isNewer(older, than: newer) || older.modificationDate == newer.modificationDate, "an unsaved record has no modification date; the tie-break must still be deterministic")
    assert(FamilySync.isNewer(newer, than: older) == (newer.recordID.recordName > older.recordID.recordName), "equal (nil) modification dates break the tie on record name")

    // Goals, subscriptions, accounts, transfers: exact money, every field back.
    let goal = Goal(name: "Trip", symbol: "airplane", tintHex: "24544A", target: Decimal(string: "1500.10")!, saved: Decimal(string: "320.55")!, scope: .shared)
    let goalBack = FamilySync.makeGoal(from: FamilySync.record(from: goal, zoneID: zoneID))
    assert(goalBack?.cloudID == goal.cloudID && goalBack?.target == goal.target && goalBack?.saved == goal.saved && goalBack?.name == "Trip", "a goal round-trips with exact money")
    assert(goalBack?.deadline == nil && goalBack?.scope == .shared, "no deadline travels as no deadline, and a synced goal lands shared")

    let personalCard = Account(name: "My card", currency: "AZN", openingBalance: 900)
    let joint = Account(name: "Joint", kind: .savings, currency: "AZN", openingBalance: Decimal(string: "250.40")!)
    joint.scope = .shared
    assert(Account(name: "Legacy").scope == .personal, "an account from before scope existed stays personal and never syncs")
    let jointBack = FamilySync.makeAccount(from: FamilySync.record(from: joint, zoneID: zoneID))
    assert(jointBack?.cloudID == joint.cloudID && jointBack?.openingBalance == joint.openingBalance && jointBack?.kind == .savings && jointBack?.scope == .shared, "an account round-trips with exact opening balance")

    let rent = Subscription(name: "Rent", amount: Decimal(string: "700.99")!, nextPaymentDate: Date(timeIntervalSince1970: 1_790_000_000), reminderDays: 3, scope: .shared, category: nil)
    rent.authorID = "partner"
    rent.account = personalCard
    let rentRecord = FamilySync.record(from: rent, zoneID: zoneID)
    let rentBack = FamilySync.makeSubscription(from: rentRecord)
    assert(rentBack?.id == rent.id && rentBack?.amount == rent.amount && rentBack?.anchorDay == rent.anchorDay && rentBack?.authorID == "partner", "a subscription round-trips with exact money, anchor and author")
    assert(rentBack?.reminderDays == nil, "a reminder is this phone's preference, not the partner's")
    assert(FamilySync.accountID(in: rentRecord) == nil, "a personal account's id never leaves the device")
    rent.account = joint
    assert(FamilySync.accountID(in: FamilySync.record(from: rent, zoneID: zoneID)) == joint.cloudID, "a shared account link travels")

    assert(Subscriptions.chargesOnThisDevice(scope: .personal, authorID: "partner", meID: "me"), "personal is always billed here")
    assert(Subscriptions.chargesOnThisDevice(scope: .shared, authorID: "", meID: "me"), "an unstamped shared subscription predates sharing: billed here")
    assert(Subscriptions.chargesOnThisDevice(scope: .shared, authorID: "me", meID: "me"), "the author's phone bills it")
    assert(!Subscriptions.chargesOnThisDevice(scope: .shared, authorID: "partner", meID: "me"), "the partner's phone must not bill the same month again")
    assert(!Subscriptions.chargesOnThisDevice(scope: .shared, authorID: "partner", meID: ""), "unknown identity is not a licence to bill someone else's subscription")

    let topUp = Transfer(amount: Decimal(string: "50.25")!, from: personalCard, to: joint)
    assert(FamilySync.isShared(topUp) && !FamilySync.isShared(Transfer(amount: 5, from: personalCard, to: Account(name: "Wallet"))), "a transfer travels only when it touches a shared account")
    let topUpRecord = FamilySync.record(from: topUp, zoneID: zoneID)
    assert(FamilySync.accountID(in: topUpRecord, key: "fromID") == nil && FamilySync.accountID(in: topUpRecord, key: "toID") == joint.cloudID, "a transfer carries only the shared side")
    assert(FamilySync.makeTransfer(from: topUpRecord)?.amount == topUp.amount, "a transfer round-trips with exact money")

    let spend = Transaction(amount: 12, merchant: "Cafe", scope: .shared, category: nil)
    spend.account = personalCard
    assert(FamilySync.accountID(in: FamilySync.record(from: spend, zoneID: zoneID)) == nil, "a shared expense paid from a personal card does not reveal the card")

    let a = UUID(), b = UUID()
    assert(FamilySync.duplicateIndices([a, b, a, a]) == [2, 3], "every repeat after the first needs a fresh id")
    assert(FamilySync.duplicateIndices([a, b]).isEmpty)
    assert(FamilySync.uuid(in: "goal-" + a.uuidString, prefix: "goal") == a && FamilySync.uuid(in: a.uuidString, prefix: "goal") == nil, "record names dispatch by prefix; bare UUIDs stay transactions")
    assert(FamilySync.applyOrder(FamilySync.accountRecordType) < FamilySync.applyOrder(FamilySync.transferRecordType), "accounts apply before what links to them")
}
#endif
