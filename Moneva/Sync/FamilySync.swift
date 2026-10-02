import Foundation
import CloudKit
import SwiftData
import Observation

/// Local ⇄ CloudKit mapping and merge rules for family-shared records.
/// Pure functions only — the stateful `CKSyncEngine` plumbing lives in
/// `FamilySyncEngine` below. Phase 1 covers `Transaction` only; Budget,
/// BudgetLimit, Goal and SubscriptionPayment follow the same shape later.
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
        // Categories travel denormalized: the partner's store has its own
        // SpendingCategory rows, and syncing those would drag personal-scope
        // ones along with them.
        record["categoryName"] = (transaction.category?.name ?? "") as CKRecordValue
        record["categorySymbol"] = (transaction.category?.symbol ?? "") as CKRecordValue
        record["categoryTint"] = (transaction.category?.tintHex ?? "") as CKRecordValue
        record["categorySoft"] = (transaction.category?.softHex ?? "") as CKRecordValue
        return record
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
        guard let role = storedRole else { return }
        for member in (try? context.fetch(FetchDescriptor<FamilyMember>())) ?? [] {
            memberNames[member.memberID] = member.name
        }
        FamilySyncStatus.shared.role = role
        start(role: role, ownerName: storedOwnerName)
    }

    /// Called by `AppDelegate` once this device has accepted the partner's
    /// invite, and by `makeOrFetchShare()` once this device has created one.
    func acceptedShare(role: FamilyRole, ownerName: String?) {
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
        if let existing = try? await db.record(for: shareID) as? CKShare {
            return existing
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "Moneva family budget" as CKRecordValue
        _ = try await db.save(share)
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
        Task { await resolveIdentity(role: role, ownerName: ownerName) }
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
    }

    private func handleSave(_ changed: Set<PersistentIdentifier>) {
        guard let syncEngine, let zoneID, let context else { return }
        var toSave: [CKSyncEngine.PendingRecordZoneChange] = []
        var toDelete: [CKSyncEngine.PendingRecordZoneChange] = []
        for id in changed {
            switch context.model(for: id) {
            case let transaction as Transaction:
                if FamilySync.shouldDeleteRemote(hadSystemFields: transaction.ckSystemFields != nil, scope: transaction.scope) {
                    toDelete.append(.deleteRecord(FamilySync.recordID(for: transaction.cloudID, zoneID: zoneID)))
                    transaction.ckSystemFields = nil
                } else if transaction.scope == .shared {
                    // Stamped here, once, rather than at every save site that
                    // can create a shared transaction.
                    if transaction.authorID.isEmpty { transaction.authorID = meID }
                    toSave.append(.saveRecord(FamilySync.recordID(for: transaction.cloudID, zoneID: zoneID)))
                }
            case let budget as Budget where budget.scope == .shared:
                let name = FamilySync.budgetRecordName(monthStart: budget.monthStart, currency: budget.currency ?? Money.code)
                toSave.append(.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID)))
            case let settlement as Settlement:
                toSave.append(.saveRecord(CKRecord.ID(recordName: FamilySync.settlementRecordName(settlement.cloudID), zoneID: zoneID)))
            default:
                continue
            }
        }
        if !toSave.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: toSave) }
        if !toDelete.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: toDelete) }
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
        case .accountChange:
            forgetShare()

        case .fetchedRecordZoneChanges(let changes):
            guard let context else { return }
            for modification in changes.modifications {
                let record = modification.record
                switch record.recordType {
                case FamilySync.budgetRecordType:
                    applyBudget(record)
                case FamilySync.settlementRecordType:
                    if let existing = settlement(recordName: record.recordID.recordName) {
                        FamilySync.apply(record, to: existing)
                    } else if let created = FamilySync.makeSettlement(from: record) {
                        context.insert(created)
                    }
                default:
                    guard let cloudID = UUID(uuidString: record.recordID.recordName) else { continue }
                    let target: Transaction?
                    if let existing = transaction(cloudID: record.recordID.recordName) {
                        FamilySync.apply(record, to: existing)
                        target = existing
                    } else if let created = FamilySync.makeTransaction(from: record, cloudID: cloudID) {
                        context.insert(created)
                        target = created
                    } else {
                        target = nil
                    }
                    if let target, let descriptor = FamilySync.categoryDescriptor(from: record, kind: target.kind) {
                        target.category = category(for: descriptor)
                    }
                }
            }
            for deletion in changes.deletions {
                if let existing = transaction(cloudID: deletion.recordID.recordName) { context.delete(existing) }
                else if let existing = settlement(recordName: deletion.recordID.recordName) { context.delete(existing) }
            }
            try? context.save()
            FamilySyncStatus.shared.lastSyncedAt = .now

        case .sentRecordZoneChanges(let sent):
            guard let zoneID else { return }
            for saved in sent.savedRecords {
                let fields = FamilySync.systemFields(from: saved)
                switch saved.recordType {
                case FamilySync.budgetRecordType: budget(recordName: saved.recordID.recordName)?.ckSystemFields = fields
                case FamilySync.settlementRecordType: settlement(recordName: saved.recordID.recordName)?.ckSystemFields = fields
                default: transaction(cloudID: saved.recordID.recordName)?.ckSystemFields = fields
                }
            }
            // Only the one failure CKSyncEngine leaves to the app; everything
            // else (throttling, network, expired tokens) is its own job.
            for failure in sent.failedRecordSaves where failure.error.code == .serverRecordChanged {
                guard let server = failure.error.serverRecord,
                      let existing = transaction(cloudID: server.recordID.recordName) else { continue }
                let mine = FamilySync.record(from: existing, zoneID: zoneID)
                if FamilySync.isNewer(mine, than: server) {
                    // Adopt the server's change tag *before* resending, or the
                    // retry carries the same stale tag and fails identically —
                    // a loop, not a merge.
                    existing.ckSystemFields = FamilySync.systemFields(from: server)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
                } else {
                    FamilySync.apply(server, to: existing)
                }
            }

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
            guard case .saveRecord(let recordID) = change else { return }
            let name = recordID.recordName
            if name.hasPrefix("budget-") {
                if let budget = budget(recordName: name) { result[recordID] = FamilySync.record(from: budget, zoneID: zoneID) }
            } else if name.hasPrefix("settlement-") {
                if let settlement = settlement(recordName: name) { result[recordID] = FamilySync.record(from: settlement, zoneID: zoneID) }
            } else if let transaction = transaction(cloudID: name) {
                result[recordID] = FamilySync.record(from: transaction, zoneID: zoneID)
            }
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
}
#endif
