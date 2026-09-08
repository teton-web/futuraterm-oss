import Foundation

/// CLI-only companion-app launch. Resolves the enclosing `.app` when this
/// binary is nested, otherwise `open -b` for the release then debug bundle
/// ids. No AppKit — LaunchServices is `/usr/bin/open`.
enum ControlLaunch {
    struct LaunchError: Error, CustomStringConvertible {
        var description: String
    }

    /// Launch once. Nested path wins so a Debug CLI cannot start Release.
    static func launchCompanion(cliExecutable: URL? = nil) throws {
        let executable = cliExecutable
            ?? Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        if let app = ControlReadiness.companionAppURL(cliExecutable: executable) {
            try runOpen(ControlReadiness.openArguments(appURL: app))
            return
        }
        var lastError: LaunchError?
        for bundleID in ControlReadiness.launchBundleIDs {
            do {
                try runOpen(ControlReadiness.openArguments(bundleID: bundleID))
                return
            } catch let error as LaunchError {
                lastError = error
            }
        }
        throw lastError ?? LaunchError(description: "could not launch FuturaTerm")
    }

    private static func runOpen(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw LaunchError(description: error.localizedDescription)
        }
        // Read before waitUntilExit so a chatty `open` can't fill the pipe.
        let errData = try? err.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = errData.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LaunchError(
                description: detail.isEmpty
                    ? "open exited \(process.terminationStatus)"
                    : detail
            )
        }
    }
}
