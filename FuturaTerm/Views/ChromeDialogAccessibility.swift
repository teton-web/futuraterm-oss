import Foundation

/// Spoken titles and values for command palette, quit confirmation, and
/// new-project/folder dialogs. Combined onto the dialog or row so VoiceOver
/// hears one name; decorative children stay hidden.
enum ChromeDialogAccessibility {
    static let commandPalette = "Command Palette"
    static let filter = "Filter"
    static let newRemoteProject = "New Remote Project"
    static let newFolder = "New Folder"
    static let newFolderName = "Name"
    static let cancel = "Cancel"
    static let quit = "Quit"
    static let create = "Create"
    static let add = "Add"
    static let runningProcesses = "Running processes"

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
