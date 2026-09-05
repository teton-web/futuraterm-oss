import Foundation
@testable import FuturaTerm
import Testing

@MainActor
struct GrokSessionStoreTests {
    private func chrome(created: Date, updated: Date? = nil) -> GrokSessionChrome {
        GrokSessionChrome(
            sessionID: "01a06730-0b9b-7ab2-a19a-7a635bdeaf71",
            createdAt: created,
            updatedAt: updated,
            title: "Start date chrome"
        )
    }

    @Test
    func cache_publishes_glance_for_older_sessions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let created = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 12))
        )
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))
        )
        let store = GrokSessionStore(isTestRun: { true })
        store.cache(chrome(created: created), for: "futuraterm-proj-aaaaaaaaaaaa")
        #expect(store.glanceLabel(for: "futuraterm-proj-aaaaaaaaaaaa", now: now) != nil)
        #expect(store.glanceLabel(for: "unknown") == nil)
    }

    @Test
    func resolve_skips_io_during_test_runs() async {
        let flag = CallFlag()
        let lookup: @Sendable (pid_t, String?, String) -> GrokSessionChrome? = { _, _, _ in
            flag.called = true
            return nil
        }
        let store = GrokSessionStore(lookup: lookup, isTestRun: { true })
        store.resolve(sessionName: "futuraterm-proj-aaaaaaaaaaaa", pid: 42, cwd: "/tmp")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(!flag.called)
        #expect(store.chromeBySessionName.isEmpty)
    }

    @Test
    func resolve_publishes_lookup_result() async {
        let expected = chrome(created: Date(timeIntervalSince1970: 1_693_526_400))
        let lookup: @Sendable (pid_t, String?, String) -> GrokSessionChrome? = { pid, cwd, home in
            #expect(pid == 42)
            #expect(cwd == "/tmp/proj")
            #expect(home == "/tmp/grok-home")
            return expected
        }
        let store = GrokSessionStore(
            lookup: lookup,
            grokHome: { "/tmp/grok-home" },
            isBenchmarkEnabled: { false },
            isTestRun: { false }
        )
        store.resolve(sessionName: "futuraterm-proj-aaaaaaaaaaaa", pid: 42, cwd: "/tmp/proj")
        var published: GrokSessionChrome?
        for _ in 0 ..< 50 {
            published = store.chromeBySessionName["futuraterm-proj-aaaaaaaaaaaa"]
            if published != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(published == expected)
        #expect(store.detailLine(for: "futuraterm-proj-aaaaaaaaaaaa")?.hasPrefix("Started ") == true)
    }
}

private final class CallFlag: @unchecked Sendable {
    var called = false
}
