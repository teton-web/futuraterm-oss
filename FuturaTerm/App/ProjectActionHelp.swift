/// Exact hover-help copy for Unload vs Remove (POR-340).
///
/// One pair of sentences, shared by the sidebar context menu, Settings →
/// Projects row menu, and `AppCommand.help`, so those sites cannot drift.
enum ProjectActionHelp {
    static let unload =
        "Stop this project's terminals but keep it in the sidebar. Select it again to restore the same tabs with new shells."
    static let remove =
        "Remove this project from the sidebar and end its sessions. Saved layout files on disk are kept."

    static func help(for command: AppCommand) -> String? {
        switch command {
        case .unloadProject: unload
        case .removeProject: remove
        default: nil
        }
    }
}
