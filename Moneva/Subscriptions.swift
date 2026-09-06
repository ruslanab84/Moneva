import Foundation
import SwiftData

/// Every date and amount a recurring payment needs, in Swift. No model ever
/// computes a billing date — it only ever suggests one for a human to confirm.
enum Subscriptions {
    /// Safety valve: a corrupt stored date must not spin the catch-up loop.
    static let maxCatchUp = 60

    /// The month a charge belongs to. Two charges can never share one.
    static func billingPeriod(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// One month on, landing on the same day of the month. February pulls a
    /// 31st back to the 28th without losing the anchor for March.
    static func nextDate(after date: Date, anchorDay: Int, calendar: Calendar = .current) -> Date {
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: date) else { return date }
        return dateInMonth(of: nextMonth, anchorDay: anchorDay, like: date, calendar: calendar)
    }

    /// Same month as `month`, on the anchor day clamped to that month's length,
    /// keeping the time of day of `like`.
    static func dateInMonth(of month: Date, anchorDay: Int, like: Date, calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.year, .month, .hour, .minute, .second], from: month)
        parts.hour = calendar.component(.hour, from: like)
        parts.minute = calendar.component(.minute, from: like)
        parts.second = 0
        let length = calendar.range(of: .day, in: .month, for: month)?.count ?? 28
        parts.day = min(max(anchorDay, 1), length)
        return calendar.date(from: parts) ?? month
    }

    /// A fixed-term plan stops after its last payment date; an open-ended one
    /// never does.
    static func hasEnded(_ subscription: Subscription, on date: Date, calendar: Calendar = .current) -> Bool {
        guard let end = subscription.endDate else { return false }
        return calendar.startOfDay(for: date) > calendar.startOfDay(for: end)
    }

    /// Charges still to come, counting the next one. nil when open-ended.
    // ponytail: walks month by month, capped; fine for loans, revisit if anything bills daily.
    static func remainingPayments(nextPaymentDate: Date, anchorDay: Int, endDate: Date?, calendar: Calendar = .current) -> Int? {
        guard let endDate else { return nil }
        let last = calendar.startOfDay(for: endDate)
        var cursor = nextPaymentDate
        var count = 0
        while calendar.startOfDay(for: cursor) <= last, count < 1200 {
            count += 1
            cursor = nextDate(after: cursor, anchorDay: anchorDay, calendar: calendar)
        }
        return count
    }

    /// Charges that should already have happened and have not been recorded.
    /// Driven by the stored next date, then filtered against the periods
    /// already on file, so a launch after two quiet months cannot double-bill.
    static func duePeriods(
        nextPaymentDate: Date,
        anchorDay: Int,
        processed: Set<String>,
        endDate: Date? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [(period: String, date: Date)] {
        var due: [(period: String, date: Date)] = []
        var cursor = nextPaymentDate
        var guardCount = 0
        let last = endDate.map { calendar.startOfDay(for: $0) }
        while cursor <= now, guardCount < maxCatchUp {
            if let last, calendar.startOfDay(for: cursor) > last { break }
            let period = billingPeriod(for: cursor, calendar: calendar)
            if !processed.contains(period) { due.append((period, cursor)) }
            cursor = nextDate(after: cursor, anchorDay: anchorDay, calendar: calendar)
            guardCount += 1
        }
        return due
    }

    static func firstFutureDate(_ subscription: Subscription, now: Date, calendar: Calendar = .current) -> Date {
        if subscription.nextPaymentDate >= calendar.startOfDay(for: now) { return subscription.nextPaymentDate }
        let candidate = dateInMonth(of: now, anchorDay: subscription.anchorDay, like: subscription.nextPaymentDate, calendar: calendar)
        return candidate >= calendar.startOfDay(for: now) ? candidate : nextDate(after: candidate, anchorDay: subscription.anchorDay, calendar: calendar)
    }

    /// Day the reminder fires, or nil when reminders are off.
    static func reminderDate(paymentDate: Date, daysBefore: Int?, calendar: Calendar = .current) -> Date? {
        guard let daysBefore else { return nil }
        return calendar.date(byAdding: .day, value: -daysBefore, to: paymentDate)
    }

    static func monthlyTotal(_ subscriptions: [Subscription], currency: String = Money.code, now: Date = .now, calendar: Calendar = .current) -> Decimal {
        subscriptions
            .filter { $0.currency == currency && !hasEnded($0, on: now, calendar: calendar) }
            .reduce(0) { $0 + $1.monthlyCost }
    }
}

/// Turns due charges into transactions. Auto-add writes; ask-before-adding
/// only ever reports, and waits for `confirm` or `skip`.
@MainActor
enum SubscriptionEngine {
    struct Pending: Identifiable {
        let subscription: Subscription
        let period: String
        let date: Date
        var id: String { "\(subscription.persistentModelID)-\(period)" }
    }

    /// Runs on launch and whenever the subscriptions screen appears. Returns
    /// the charges that still need an answer.
    @discardableResult
    static func catchUp(in context: ModelContext, now: Date = .now, calendar: Calendar = .current) throws -> [Pending] {
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        var pending: [Pending] = []

        do {
            for subscription in subscriptions where subscription.status == .active {
                let processed = Set(subscription.payments.map(\.billingPeriod))
                let due = Subscriptions.duePeriods(
                    nextPaymentDate: subscription.nextPaymentDate,
                    anchorDay: subscription.anchorDay,
                    processed: processed,
                    endDate: subscription.endDate,
                    now: now,
                    calendar: calendar
                )
                guard !due.isEmpty else { continue }

                switch subscription.paymentMode {
                case .autoAdd:
                    for charge in due { try record(subscription, period: charge.period, date: charge.date, in: context, addTransaction: true, calendar: calendar) }
                case .ask:
                    pending += due.map { Pending(subscription: subscription, period: $0.period, date: $0.date) }
                }
            }

            try context.save()
        } catch { context.rollback(); throw error }
        return pending.sorted { $0.date < $1.date }
    }

    static func confirm(_ item: Pending, in context: ModelContext, calendar: Calendar = .current) throws {
        do {
            try record(item.subscription, period: item.period, date: item.date, in: context, addTransaction: true, calendar: calendar)
            try context.save()
        } catch { context.rollback(); throw error }
    }

    /// Skipping still records the period, so the same month is never asked twice.
    static func skip(_ item: Pending, in context: ModelContext, calendar: Calendar = .current) throws {
        do {
            try record(item.subscription, period: item.period, date: item.date, in: context, addTransaction: false, calendar: calendar)
            try context.save()
        } catch { context.rollback(); throw error }
    }

    private static func record(
        _ subscription: Subscription,
        period: String,
        date: Date,
        in context: ModelContext,
        addTransaction: Bool,
        calendar: Calendar
    ) throws {
        guard subscription.modelContext != nil, subscription.status == .active,
              date >= subscription.nextPaymentDate,
              !subscription.payments.contains(where: { $0.billingPeriod == period }) else { return }

        var transaction: Transaction?
        if addTransaction {
            guard Money.valid(subscription.amount, currency: subscription.currency),
                  CategoryLibrary.isSelectable(subscription.category, scope: subscription.scope) else { throw DraftStore.Failure.invalid }
            let created = Transaction(
                amount: subscription.amount,
                date: date,
                merchant: subscription.name,
                note: subscription.note,
                kind: .expense,
                scope: subscription.scope,
                source: .subscription,
                category: subscription.category,
                currency: subscription.currency
            )
            context.insert(created)
            transaction = created
        }
        let payment = SubscriptionPayment(billingPeriod: period, subscription: subscription, transaction: transaction)
        context.insert(payment)
        if !subscription.payments.contains(where: { $0 === payment }) { subscription.payments.append(payment) }

        // Only move the clock past a period that is now on file.
        if Subscriptions.billingPeriod(for: subscription.nextPaymentDate, calendar: calendar) == period {
            subscription.nextPaymentDate = Subscriptions.nextDate(after: subscription.nextPaymentDate, anchorDay: subscription.anchorDay, calendar: calendar)
        }
    }
}
