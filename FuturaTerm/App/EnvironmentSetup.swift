import Foundation

/// Every mutation of this process's environment, in one place, run once from
/// `FuturaTermApp.init` — strictly BEFORE anything can touch `GhosttyApp.shared`.
///
/// Why the ordering is load-bearing: `ghostty_init` captures `environ` as a
/// pointer+length slice and keeps it for the life of the process — surface
/// spawns build the child shell's environment from that cached slice, and
/// libghostty exposes no C API to re-sync it (its own GTK runtime re-syncs via
/// an internal `global.syncEnviron()`). A `setenv`/`unsetenv` after init can
/// realloc `environ`, leaving ghostty's slice dangling: depending on malloc
/// layout that is a silent stale read (panes stop inheriting the new vars) or
/// a crash in the spawn path — observed as the debug app dying ~0.5s into
/// launch with a null read inside libghostty's environ scan, breakpad's
/// handler then `_exit(1)`ing with nothing on stderr.
///
/// SwiftUI triggers `GhosttyApp.shared` lazily during scene construction,
/// which can run before `applicationDidFinishLaunching` — so ADFL is too late
/// for env setup. `FuturaTermApp.init` runs before any scene builds.
/// `GhosttyApp.init` preconditions on `didRun` so a future regression of this
/// ordering fails loudly instead of corrupting spawn environments.
@MainActor
enum EnvironmentSetup {
    /// Filename of the bundled control CLI under `Resources/bin/`.
    static let bundledCLIBinaryName = ControlProtocol.cliCommandName

    private(set) static var didRun = false

    static func runOnce() {
        guard !didRun else { return }
        didRun = true

        // A launcher terminal's zmx session marker must not leak into our
        // panes (see ZmxEnvironment.scrubInheritedSession).
        ZmxEnvironment.scrubInheritedSession()

        // Control socket for the bundled `futuraterm` CLI. The path is
        // deterministic (the server binds this same path later, in
        // applicationDidFinishLaunching), so the env var can be exported
        // before the server starts — every shell must inherit it via
        // ghostty's captured environ.
        let socketPath = ControlSocketServer.defaultSocketPath()
        setenv(ControlProtocol.socketEnvVar, socketPath, 1)

        // Bundled `futuraterm` CLI on PATH for every pane, same inheritance
        // path as FUTURATERM_SOCKET above.
        if let binDir = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true).path,
           FileManager.default.isExecutableFile(atPath: binDir + "/" + bundledCLIBinaryName)
        {
            let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
            setenv("PATH", existingPath.isEmpty ? binDir : "\(binDir):\(existingPath)", 1)
        }
    }
}
