import Foundation
@testable import FuturaTerm
import Testing

@MainActor
struct PaneDumpQuietWaitTests {
    @Test
    func wait_returns_when_text_is_stable() async throws {
        let clock = FakeClock()
        let snapshot = try await PaneDumpQuietWait.wait(
            quietMs: 50,
            timeoutMs: 1000,
            now: { clock.now() },
            sleep: { clock.advance($0) },
            read: { "stable" }
        )
        #expect(snapshot.text == "stable")
        #expect(snapshot.timedOut == false)
        #expect(clock.ms >= 50)
        #expect(clock.ms < 500)
    }

    @Test
    func wait_timeout_returns_last_text() async throws {
        let clock = FakeClock()
        var n = 0
        let snapshot = try await PaneDumpQuietWait.wait(
            quietMs: 200,
            timeoutMs: 100,
            now: { clock.now() },
            sleep: { clock.advance($0) },
            read: {
                n += 1
                return "frame-\(n)"
            }
        )
        #expect(snapshot.timedOut == true)
        #expect(snapshot.text.hasPrefix("frame-"))
        #expect(clock.ms >= 100)
    }

    @Test
    func wait_nil_read_is_no_surface() async {
        do {
            _ = try await PaneDumpQuietWait.wait(
                quietMs: 50,
                timeoutMs: 1000,
                read: { nil }
            )
            Issue.record("expected no_surface")
        } catch let error as ControlError {
            #expect(error.code == .noSurface)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}

private final class FakeClock: @unchecked Sendable {
    var ms = 0
    let origin = ContinuousClock.now

    func now() -> ContinuousClock.Instant {
        origin + .milliseconds(ms)
    }

    func advance(_ duration: Duration) {
        let seconds = duration.components.seconds
        let attos = duration.components.attoseconds
        ms += Int(seconds * 1000) + Int(attos / 1_000_000_000_000_000)
    }
}
