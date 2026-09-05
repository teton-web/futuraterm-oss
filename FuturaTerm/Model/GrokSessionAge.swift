import Foundation

/// Session-start labels for Grok chrome (sidebar tab rows, session manager).
///
/// Glance labels are a calendar landmark so a multi-day session is obviously
/// not from today. Same-calendar-day sessions stay blank so new chats do not
/// grow a date. Clock time belongs on the detail layer (tooltip).
enum GrokSessionAge {
    /// Compact start label. Hidden on the local calendar day the session
    /// started. After that: `3d · Mon` this week, `12d · Sep 1` otherwise.
    static func promptGlance(
        created: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        guard let days = calendarDays(from: created, now: now, calendar: calendar), days > 0 else {
            return nil
        }
        return "\(days)d · \(landmark(created: created, days: days, calendar: calendar, locale: locale))"
    }

    /// Extra-details line for hover/help.
    ///
    /// `Started Sep 1, 12:13 PM · Updated Sep 3, 9:40 AM · 2d 4h`
    static func detailLine(
        created: Date,
        updated: Date?,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        var parts = ["Started \(clock(created, calendar: calendar, locale: locale))"]
        if let updated {
            parts.append("Updated \(clock(updated, calendar: calendar, locale: locale))")
        }
        parts.append(durationLabel(from: created, now: now))
        return parts.joined(separator: " · ")
    }

    /// Whole local calendar days from `created` to `now`, or nil when `created`
    /// is in a future day.
    static func calendarDays(from created: Date, now: Date, calendar: Calendar) -> Int? {
        let createdDay = calendar.startOfDay(for: created)
        let nowDay = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: createdDay, to: nowDay).day ?? 0
        return days < 0 ? nil : days
    }

    static func durationLabel(from created: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(created)
        if interval < 0 { return "0m" }
        let totalMinutes = Int(interval) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(max(0, minutes))m"
    }

    /// Unix-ms timestamp encoded in a UUIDv7 session id. `nil` for v4 or
    /// unparseable ids. Reads the canonical hex (not `UUID.uuid`'s host
    /// layout): the first 48 bits are `unix_ts_ms`, and the version nibble
    /// is the first character of the third group.
    static func createdAt(fromSessionID id: String) -> Date? {
        let hex = id.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        // Version nibble: character 12 of the 32-char hex form.
        guard hex[hex.index(hex.startIndex, offsetBy: 12)] == "7" else { return nil }
        guard let ms = UInt64(hex.prefix(12), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    private static func landmark(
        created: Date,
        days: Int,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        var style = if days < 7 {
            Date.FormatStyle(date: .omitted, time: .omitted).weekday(.abbreviated)
        } else {
            Date.FormatStyle(date: .omitted, time: .omitted).month(.abbreviated).day()
        }
        style.locale = locale
        style.timeZone = calendar.timeZone
        style.calendar = calendar
        return created.formatted(style)
    }

    private static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted)
            .month(.abbreviated)
            .day()
            .hour(.defaultDigits(amPM: .abbreviated))
            .minute()
        style.locale = locale
        style.timeZone = calendar.timeZone
        style.calendar = calendar
        return date.formatted(style)
    }
}
