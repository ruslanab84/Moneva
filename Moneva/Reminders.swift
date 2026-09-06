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
        cancel(subscription)

        // Reminders off means no notifications at all, and no permission
        // prompt: the subscriptions screen still asks in app when a charge is due.
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
                body: "Open Moneva to add \(subscription.amount.money(subscription.currency)) or skip this month.",
                at: subscription.nextPaymentDate,
                calendar: calendar
            ))
        }

        guard !requests.isEmpty, await authorize() else { return }
        for request in requests { try? await center.add(request) }
    }

    static func cancel(_ subscription: Subscription) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier(subscription, suffix: "reminder"), identifier(subscription, suffix: "confirm")]
        )
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
