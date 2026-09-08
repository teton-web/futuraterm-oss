import Foundation
@testable import FuturaTerm
import Testing

struct AgentUsageTests {
    @Test
    func unused_window_is_100_percent_remaining() {
        #expect(AgentUsage.remainingPercent(usedFraction: 0) == 100)
        #expect(AgentUsageSnapshot(
            kind: .grok,
            usedFraction: 0,
            periodEnd: nil,
            fetchedAt: Date()
        ).remainingPercent == 100)
    }

    @Test
    func fully_used_window_is_0_percent_remaining() {
        #expect(AgentUsage.remainingPercent(usedFraction: 1) == 0)
        #expect(AgentUsageSnapshot(
            kind: .grok,
            usedFraction: 1,
            periodEnd: nil,
            fetchedAt: Date()
        ).remainingPercent == 0)
    }

    @Test
    func remaining_percent_rounds_42_4_used_fraction() {
        // 0.424 used → 57.6 remaining → rounds to nearest (58).
        #expect(AgentUsage.remainingPercent(usedFraction: 0.424) == 58)
        // 42.5% used → 57.5 remaining → 58 (to-nearest-or-even).
        #expect(AgentUsage.remainingPercent(usedFraction: 0.425) == 58)
    }

    @Test
    func remaining_percent_clamps_outside_0_1() {
        #expect(AgentUsage.remainingPercent(usedFraction: -0.2) == 100)
        #expect(AgentUsage.remainingPercent(usedFraction: 1.5) == 0)
        #expect(AgentUsage.remainingPercent(usedFraction: 42.4) == 0)
        let snapshot = AgentUsageSnapshot(
            kind: .grok,
            usedFraction: 1.5,
            periodEnd: nil,
            fetchedAt: Date()
        )
        #expect(snapshot.usedFraction == 1)
        #expect(snapshot.remainingPercent == 0)
    }

    @Test
    func reset_caption_is_nil_when_period_end_is_nil() {
        #expect(AgentUsage.resetCaption(periodEnd: nil) == nil)
    }

    @Test
    func reset_caption_includes_abbreviated_date_and_shortened_time() throws {
        let periodEnd = Date(timeIntervalSince1970: 1_788_539_051) // 2026-09-04T16:24:11Z
        let caption = try AgentUsage.resetCaption(
            periodEnd: periodEnd,
            locale: Locale(identifier: "en_US"),
            timeZone: #require(TimeZone(identifier: "GMT"))
        )
        #expect(caption != nil)
        #expect(caption?.contains("Sep 4, 2026") == true)
        // FormatStyle inserts a narrow no-break space before AM/PM.
        #expect(caption?.contains("4:24") == true)
        #expect(caption?.contains("PM") == true)
        #expect(caption?.hasPrefix("Resets ") == true)
    }

    @Test
    func reset_caption_includes_midnight_time() throws {
        let periodEnd = Date(timeIntervalSince1970: 1_788_480_000) // 2026-09-04T00:00:00Z
        let caption = try AgentUsage.resetCaption(
            periodEnd: periodEnd,
            locale: Locale(identifier: "en_US"),
            timeZone: #require(TimeZone(identifier: "GMT"))
        )
        #expect(caption?.contains("12:00") == true)
        #expect(caption?.contains("AM") == true)
    }
}
