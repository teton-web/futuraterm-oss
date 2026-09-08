import Foundation

/// Pure launch/retry policy for the control CLI. Compiled into both the app
/// (so hosted tests can `@testable import` it) and the CLI target — no AppKit,
/// no process launch. `ControlLaunch` is the CLI-only side that invokes `open`.
enum ControlReadiness {
    /// Wall-clock budget for launch + socket wait (matches the issue contract).
    static let timeout: TimeInterval = 20

    /// Pause between send attempts while waiting for the socket / `starting`.
    static let pollInterval: TimeInterval = 0.2

    /// Release `PRODUCT_BUNDLE_IDENTIFIER` — a launch target, not the CLI's
    /// own id (`com.davidsolheim.futuraterm.cli`).
    static let releaseBundleID = "com.davidsolheim.futuraterm"

    /// Debug `PRODUCT_BUNDLE_IDENTIFIER`. Tried after release when the CLI
    /// isn't nested inside an `.app`.
    static let debugBundleID = "com.davidsolheim.futuraterm.debug"

    /// `/usr/bin/open -b` targets when there is no enclosing `.app`. Release
    /// first so a PATH-installed CLI doesn't prefer a stray debug copy.
    static let launchBundleIDs = [releaseBundleID, debugBundleID]

    /// Whether a missed socket should start the companion app. `--socket` is a
    /// hard pin (maybe not this app) and `--no-launch` restores fail-fast.
    /// `FUTURATERM_SOCKET` is only a discovery hint — it does not skip launch.
    static func shouldAutoLaunch(socketOverride: String?, noLaunch: Bool) -> Bool {
        if noLaunch { return false }
        if socketOverride != nil { return false }
        return true
    }

    /// Retryable: nothing answered, or the socket is up but the handler has
    /// not attached (`starting`). Everything else (including an ok response
    /// and an undecodable payload, which never reaches here as a response)
    /// is terminal.
    static func isRetryable(connectionFailure: Bool, response: ControlResponse?) -> Bool {
        if connectionFailure { return true }
        guard let response, !response.ok else { return false }
        return response.error?.code == .starting
    }

    /// Nested CLI layout: `<App>.app/Contents/Resources/bin/futuraterm`
    /// (Release `FuturaTerm.app`, Debug `FuturaTermDebug.app`). Prefer this
    /// over LaunchServices so a Debug CLI never starts Release (different
    /// App Support / socket). `nil` if the executable isn't nested.
    static func companionAppURL(cliExecutable: URL) -> URL? {
        let file = cliExecutable.standardizedFileURL.resolvingSymlinksInPath()
        let bin = file.deletingLastPathComponent()
        let resources = bin.deletingLastPathComponent()
        let contents = resources.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard bin.lastPathComponent == "bin",
              resources.lastPathComponent == "Resources",
              contents.lastPathComponent == "Contents",
              app.pathExtension == "app"
        else { return nil }
        return app
    }

    /// Arguments for `/usr/bin/open` given a resolved `.app`. Never includes
    /// `-n` — this is a single-window app; a second instance is a bug.
    static func openArguments(appURL: URL) -> [String] {
        [appURL.path]
    }

    /// Arguments for `/usr/bin/open -b <bundleId>`. Never includes `-n`.
    static func openArguments(bundleID: String) -> [String] {
        ["-b", bundleID]
    }
}
