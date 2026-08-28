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
}
