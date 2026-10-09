import Foundation

/// Free scan/voice entries used this calendar month. The month is part of the
/// key, so a new month starts at zero with no reset code.
// ponytail: UserDefaults is wiped by a reinstall, which resets the allowance.
// Upgrade path: iCloud key-value store if abuse ever matters.
enum AIUsage {
    static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "aiUsage.%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func count(now: Date = .now, calendar: Calendar = .current, defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: key(for: now, calendar: calendar))
    }

    static func record(now: Date = .now, calendar: Calendar = .current, defaults: UserDefaults = .standard) {
        defaults.set(count(now: now, calendar: calendar, defaults: defaults) + 1, forKey: key(for: now, calendar: calendar))
    }
}
