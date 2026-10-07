import Foundation
import UserNotifications

/// Local reminders for recurring payments. Permission is only ever asked for
/// when the user actually turns a reminder on.
enum Reminders {
    /// Asks once. Returns false when the user has said no before, so callers
    /// can explain instead of silently doing nothing.
    static func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    /// Replaces whatever was scheduled for this subscription. Called after
    /// every create, edit, pause and resume.
    static func reschedule(_ subscription: Subscription, calendar: Calendar = .current) async {
        let center = UNUserNotificationCenter.current()
        cancel(subscription, includingTrial: subscription.status != .active)

        // Renewal reminders off means no renewal notifications or permission
        // prompt. Trial reminders are managed separately by catchUp.
        // A finished plan has nothing left to announce.
        guard subscription.status == .active, subscription.reminderDays != nil,
              !Subscriptions.hasEnded(subscription, on: subscription.nextPaymentDate, calendar: calendar) else { return }
        var requests: [UNNotificationRequest] = []

        if let fireDate = Subscriptions.reminderDate(paymentDate: subscription.nextPaymentDate, daysBefore: subscription.reminderDays, calendar: calendar) {
            requests.append(request(
                id: identifier(subscription, suffix: "reminder"),
                title: "\(subscription.name) renews soon",
                body: "\(subscription.amount.money(subscription.currency)) on \(subscription.nextPaymentDate.formatted(date: .abbreviated, time: .omitted)).",
                at: fireDate,
                calendar: calendar
            ))
        }

        // Ask-before-adding needs a nudge on the day itself, or the charge sits
        // unanswered until the app happens to be opened.
        if subscription.paymentMode == .ask {
            requests.append(request(
                id: identifier(subscription, suffix: "confirm"),
                title: "\(subscription.name) is due today",
                body: "Open Ledgea to add \(subscription.amount.money(subscription.currency)) or skip this month.",
                at: subscription.nextPaymentDate,
                calendar: calendar
            ))
        }

        guard !requests.isEmpty, await authorize() else { return }
        for request in requests { try? await center.add(request) }
    }

    static func cancel(_ subscription: Subscription, includingTrial: Bool = true) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier(subscription, suffix: "reminder"), identifier(subscription, suffix: "confirm")]
                + (includingTrial ? [identifier(subscription, suffix: "trial")] : [])
        )
    }

    /// Called only by catchUp. Existing notification permission is respected;
    /// catch-up never prompts on launch or changes ordinary renewal reminders.
    static func registerTrial(_ subscription: Subscription, now: Date, calendar: Calendar) {
        let center = UNUserNotificationCenter.current()
        let id = identifier(subscription, suffix: "trial")
        guard let request = trialRequest(subscription, now: now, calendar: calendar) else {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        // A stable identifier replaces an earlier request when the trial changes.
        center.add(request) { error in
            if let error { NSLog("Trial reminder could not be scheduled: %@", error.localizedDescription) }
        }
    }

    static func trialRequest(_ subscription: Subscription, now: Date, calendar: Calendar) -> UNNotificationRequest? {
        guard subscription.status == .active, let end = subscription.trialEndsAt,
              subscription.nextPaymentDate <= end,
              !Subscriptions.hasEnded(subscription, on: end, calendar: calendar),
              let fire = Subscriptions.reminderDate(paymentDate: end, daysBefore: 2, calendar: calendar),
              fire > now else { return nil }
        let content = UNMutableNotificationContent()
        content.title = "\(subscription.name) trial ends soon"
        content.body = "Your trial ends on \(end.formatted(date: .abbreviated, time: .omitted))."
        content.sound = .default
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        parts.calendar = calendar
        parts.timeZone = calendar.timeZone
        return UNNotificationRequest(identifier: identifier(subscription, suffix: "trial"), content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    private static func identifier(_ subscription: Subscription, suffix: String) -> String {
        "subscription-\(subscription.id.uuidString)-\(suffix)"
    }

    private static func request(id: String, title: String, body: String, at date: Date, calendar: Calendar) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = 9
        parts.minute = 0
        return UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        )
    }
}
