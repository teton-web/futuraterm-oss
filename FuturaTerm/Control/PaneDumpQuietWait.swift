import Foundation

/// Bounded poll for `pane.dump --quiet-ms`: re-read until the text is
/// unchanged for `quietMs`, or `timeoutMs` elapses. Sleeps with `Task.sleep`
/// so the MainActor can service other control connections.
enum PaneDumpQuietWait {
    static let minQuietMs = 50
    static let maxQuietMs = 2000
    static let minTimeoutMs = 100
    static let maxTimeoutMs = 30000
    static let defaultTimeoutMs = 5000
    static let pollMs = 50

    static let noSurface = ControlError(
        code: .noSurface,
        message: "the pane's terminal isn't live yet",
        action: "select its tab once so the surface spawns, then retry"
    )

    struct Snapshot {
        var text: String
        var timedOut: Bool
    }

    static func validate(_ args: ControlArgs) throws -> (quietMs: Int, timeoutMs: Int) {
        guard let quietMs = args.quietMs else {
            throw ControlError(code: .badRequest, message: "quietMs is required")
        }
        guard (minQuietMs ... maxQuietMs).contains(quietMs) else {
            throw ControlError(
                code: .badRequest,
                message: "quietMs must be between \(minQuietMs) and \(maxQuietMs)",
                action: "pass --quiet-ms in that range"
            )
        }
        let timeoutMs = args.timeoutMs ?? defaultTimeoutMs
        guard (minTimeoutMs ... maxTimeoutMs).contains(timeoutMs) else {
            throw ControlError(
                code: .badRequest,
                message: "timeoutMs must be between \(minTimeoutMs) and \(maxTimeoutMs)",
                action: "pass --timeout-ms in that range"
            )
        }
        return (quietMs, timeoutMs)
    }

    @MainActor
    static func wait(
        quietMs: Int,
        timeoutMs: Int,
        now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        read: @MainActor () async throws -> String?
    ) async throws -> Snapshot {
        let deadline = now() + .milliseconds(timeoutMs)
        guard let first = try await read() else {
            throw noSurface
        }
        var last = first
        var lastChange = now()
        while true {
            let t = now()
            if t - lastChange >= .milliseconds(quietMs) {
                return Snapshot(text: last, timedOut: false)
            }
            if t >= deadline {
                return Snapshot(text: last, timedOut: true)
            }
            let remainingQuiet = Duration.milliseconds(quietMs) - (t - lastChange)
            let remainingTimeout = deadline - t
            let slice = min(Duration.milliseconds(pollMs), remainingQuiet, remainingTimeout)
            if slice > .zero {
                try await sleep(slice)
            }
            guard let next = try await read() else {
                throw noSurface
            }
            if next != last {
                last = next
                lastChange = now()
            }
        }
    }
}
