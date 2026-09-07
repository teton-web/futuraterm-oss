import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "ExternalZmxAttach")

/// Opens a local zmx session in the user's default terminal app via a temp
/// `.command` file and Launch Services. Uses the bundled zmx binary only.
enum ExternalZmxAttach {
    /// POSIX single-quote: wrap in `'…'` and rewrite interior `'` as `'"'"'`.
    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Shebang script that `exec`s bundled zmx `attach` with the session name
    /// as a shell-single-quoted literal (`NSWorkspace.open` drops extra argv).
    /// Exports `ZMX_DIR` so Terminal.app looks in the same socket dir MAS pinned
    /// (container / entitled config), not the unsandboxed `/tmp/zmx-<uid>`.
    static func commandFileContents(zmxPath: String, sessionName: String, zmxDir: String) -> String {
        """
        #!/bin/sh
        export ZMX_DIR=\(shellSingleQuote(zmxDir))
        exec \(shellSingleQuote(zmxPath)) attach \(shellSingleQuote(sessionName))

        """
    }

    static func bundledZmxURL() -> URL? {
        Bundle.main.url(forResource: "zmx", withExtension: nil, subdirectory: "zmx")
    }

    /// Writes an executable temp `.command` and opens it with Launch Services.
    /// Falls back to Terminal.app only when LS has no default for the file.
    /// Returns false when zmx is missing or the file cannot be written; never throws.
    @discardableResult
    @MainActor
    static func open(
        sessionName: String,
        zmxURL: URL?,
        workspace: NSWorkspace = .shared
    ) -> Bool {
        guard let zmxURL else { return false }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-zmx-attach-\(UUID().uuidString).command")
        let body = commandFileContents(
            zmxPath: zmxURL.path,
            sessionName: sessionName,
            zmxDir: ZmxSocketBudget.socketDir()
        )
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: file.path
            )
        } catch {
            logger.error("temp .command failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let defaultApp = workspace.urlForApplication(toOpen: file)
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        if let defaultApp {
            workspace.open(
                [file],
                withApplicationAt: defaultApp,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return true
        }
        return workspace.open(file)
    }
}
