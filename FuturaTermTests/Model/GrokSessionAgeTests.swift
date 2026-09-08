import Foundation
@testable import FuturaTerm
import Testing

struct GrokSessionAgeTests {
    private let locale = Locale(identifier: "en_US_POSIX")

    private func utcCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        calendar.locale = locale
        return calendar
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return try #require(utcCalendar().date(from: components))
    }

    @Test
    func same_day_hides_glance_label() throws {
        let utc = try utcCalendar()
        let created = try utcDate(2026, 9, 3, hour: 8)
        let now = try utcDate(2026, 9, 3, hour: 18)
        #expect(GrokSessionAge.promptGlance(created: created, now: now, calendar: utc, locale: locale) == nil)
        #expect(GrokSessionAge.calendarDays(from: created, now: now, calendar: utc) == 0)
    }

    @Test
    func this_week_uses_weekday_and_relative_days() throws {
        let utc = try utcCalendar()
        let created = try utcDate(2026, 8, 31)
        let now = try utcDate(2026, 9, 3)
        let glance = GrokSessionAge.promptGlance(created: created, now: now, calendar: utc, locale: locale)
        #expect(glance == "3d · Mon")
    }

    @Test
    func older_sessions_use_month_day() throws {
        let utc = try utcCalendar()
        let created = try utcDate(2026, 8, 1)
        let now = try utcDate(2026, 9, 3)
        let glance = GrokSessionAge.promptGlance(created: created, now: now, calendar: utc, locale: locale)
        #expect(glance == "33d · Aug 1")
    }

    @Test
    func future_day_hides_glance() throws {
        let utc = try utcCalendar()
        let created = try utcDate(2026, 9, 4)
        let now = try utcDate(2026, 9, 3)
        #expect(GrokSessionAge.promptGlance(created: created, now: now, calendar: utc, locale: locale) == nil)
        #expect(GrokSessionAge.calendarDays(from: created, now: now, calendar: utc) == nil)
    }

    @Test
    func detail_line_includes_clock_and_duration() throws {
        let utc = try utcCalendar()
        let created = try utcDate(2026, 9, 1, hour: 12)
        let updated = try utcDate(2026, 9, 3, hour: 9)
        let now = try utcDate(2026, 9, 3, hour: 12)
        let line = GrokSessionAge.detailLine(
            created: created,
            updated: updated,
            now: now,
            calendar: utc,
            locale: locale
        )
        #expect(line.hasPrefix("Started "))
        #expect(line.contains("Updated "))
        #expect(line.contains("2d 0h"))
    }

    @Test
    func duration_uses_hours_and_minutes_under_a_day() throws {
        let created = try utcDate(2026, 9, 3, hour: 10)
        let now = try utcDate(2026, 9, 3, hour: 12)
        #expect(GrokSessionAge.durationLabel(from: created, now: now) == "2h")
        let minutesLater = created.addingTimeInterval(3 * 60)
        #expect(GrokSessionAge.durationLabel(from: created, now: minutesLater) == "3m")
        #expect(GrokSessionAge.durationLabel(from: now, now: created) == "0m")
    }

    @Test
    func uuidv7_yields_embedded_timestamp() throws {
        let id = "018a4e3c-0000-7000-8000-000000000000"
        let parsed = try #require(GrokSessionAge.createdAt(fromSessionID: id))
        #expect(parsed.timeIntervalSince1970 == TimeInterval(0x018A_4E3C_0000) / 1000)
        #expect(GrokSessionAge.createdAt(fromSessionID: "not-a-uuid") == nil)
        #expect(GrokSessionAge.createdAt(fromSessionID: "550e8400-e29b-41d4-a716-446655440000") == nil)
    }
}
