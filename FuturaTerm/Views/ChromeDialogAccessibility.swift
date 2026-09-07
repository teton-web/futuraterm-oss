import Foundation

/// Spoken titles and values for command palette, quit confirmation, and
/// new-project/folder dialogs. Combined onto the dialog or row so VoiceOver
/// hears one name; decorative children stay hidden.
enum ChromeDialogAccessibility {
    static let commandPalette = "Command Palette"
    static let filter = "Filter"
    static let newRemoteProject = "New Remote Project"
    static let viewDesktop = "View Desktop"
    static let viewDesktopMissingMoonlight =
        DesktopView.moonlightMissingReason
    static let viewDesktopLaunchFailed =
        DesktopView.moonlightLaunchFailedReason
    static let viewDesktopMissingVNC =
        "A VNC viewer is not installed. Install a VNC viewer to view this machine's screen."
    static let viewDesktopNotRemote = "View Desktop is available on a remote project."
    static let tailscaleDevices = "Tailscale Devices"
    static let tailscaleUnavailableNotInstalled = "Tailscale is not installed. Enter a host instead."
    static let tailscaleUnavailableNeedsLogin = "Tailscale is not logged in. Enter a host instead."
    static let tailscaleUnavailableStopped = "Tailscale is not running. Enter a host instead."
    static let tailscaleUnavailableError = "Couldn’t read Tailscale status. Enter a host instead."
    static let tailscaleNoDevices = "No other devices on this tailnet."
    static let enterHostManually = "Enter Host Manually"
    static let chooseDirectory = "Choose Project Directory"
    static let back = "Back"
    static let openExisting = "Open Existing"
    static let sessions = "Sessions"
    static let environments = "Environments"
    static let newFolder = "New Folder"
    static let newFolderName = "Name"
    static let cancel = "Cancel"
    static let quit = "Quit"
    static let create = "Create"
    static let add = "Add"
    static let kill = "Kill"
    static let openInFuturaTerm = "Open in FuturaTerm"
    static let openInBrowser = "Open in Browser"
    static let showInFuturaTerm = "Show in FuturaTerm"
    static let couldNotOpenAddress = "Couldn’t open that address."
    static let openInDefaultTerminal = "Open in Default Terminal"
    static let zmxNotAvailable = "zmx is not available"
    static let needsLocalProject = "Open a local project first."
    static let sessionNotFound = "Session not found."
    static let killAttachedWarning = "Sessions open in FuturaTerm will close their panes."
    static let killServerWarning = "The process listening on that port will receive SIGTERM."
    static let runningProcesses = "Running processes"

    static func killSessionsTitle(count: Int) -> String {
        count == 1 ? "Kill Session?" : "Kill \(count) Sessions?"
    }

    static func killServerTitle(count: Int) -> String {
        count == 1 ? "Kill Server?" : "Kill \(count) Servers?"
    }

    /// Confirm body: up to 8 `command · port` lines, then “and M more”, then SIGTERM warning.
    static func killServerMessage(lines: [String]) -> String {
        let listed = Array(lines.prefix(8))
        var body = listed
        if lines.count > 8 {
            body.append("and \(lines.count - 8) more")
        }
        body.append(killServerWarning)
        return body.joined(separator: "\n")
    }

    /// Confirm body: up to 8 names, then “and M more”; attached warning last.
    static func killSessionsMessage(names: [String], includesAttached: Bool) -> String {
        let listed = Array(names.prefix(8))
        var lines = listed
        if names.count > 8 {
            lines.append("and \(names.count - 8) more")
        }
        if includesAttached {
            lines.append(killAttachedWarning)
        }
        return lines.joined(separator: "\n")
    }

    static func quitDialogLabel(appName: String) -> String {
        "Quit \(appName)?"
    }

    /// Titlebar string. The question mark lives on the dialog AX label, not
    /// the window title, so VoiceOver does not hear the same title twice.
    static func quitWindowTitle(appName: String) -> String {
        "Quit \(appName)"
    }

    static func quitRunningMessage(count: Int) -> String {
        if count == 1 {
            "1 process is still running. Quit anyway?"
        } else {
            "\(count) processes are still running. Quit anyway?"
        }
    }

    static func quitProcessRow(projectName: String, processName: String) -> String {
        "\(projectName), \(processName)"
    }

    /// Fallback spoken list when SwiftUI `Table` exposes no row children.
    static func quitProcessList(_ rows: [RunningProcessRow]) -> String {
        rows.map { quitProcessRow(projectName: $0.projectName, processName: $0.processName) }
            .joined(separator: "; ")
    }

    /// Spoken subtitle for a palette row. `nil` when there is nothing to
    /// announce so VoiceOver does not read an empty value.
    static func paletteRowValue(_ subtitle: String?) -> String? {
        guard let subtitle else { return nil }
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
