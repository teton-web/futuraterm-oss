/// Hover-help copy for remaining visible chrome (POR-343).
///
/// One-sentence `.help` on hoverable buttons and menu *labels* — not File-menu
/// items (POR-341) or sidebar context-menu items (POR-342). The + New Project
/// and Settings project-row ⋯ strings are the ticket's pre-decided copy.
enum ChromeHelp {
    static let newProject =
        "Add a local folder, a remote machine, or a sidebar folder."
    static let sessions =
        "Show every local terminal session and whether it is open in a project."
    static let environments =
        "Show local development servers listening on this Mac."
    static let viewDesktop =
        "Open a live view of this remote machine's screen."
    static let projectRowMenu =
        "Apply or save layout, reorder, unload, or remove this project."
    static let layoutRowMenu =
        "Create a project from this file, or delete the layout file."
    static let ghosttyConfigRowMenu =
        "Edit, reorder, or remove this config file."
    static let searchOlder =
        "Find the next match toward older output."
    static let searchNewer =
        "Find the next match toward newer output."
    static let closeSearch = "Close search."
    static let expandFolder = "Expand this folder."
    static let collapseFolder = "Collapse this folder."
    static let revealLayoutsFolder = "Reveal the layouts folder in Finder."
    static let openFullDiskAccess =
        "Open Full Disk Access in System Settings."
    static let openNotificationSettings =
        "Open notification settings for FuturaTerm."
    static let recordKeybind = "Click to record a new shortcut."
}
