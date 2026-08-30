/// Hover-help copy for sidebar context menus and the New Project + menu (POR-342).
///
/// Pin / Unpin / Close Tab / Delete Folder / Separate Panes / Local Folder /
/// Remote Machine / New Folder are the pre-decided sentences from the ticket.
/// The rest are the same tone: sentence case, one line, what happens.
enum SidebarMenuHelp {
    static let pinTab =
        "Keep this tab above projects. It restores its layout even after the session dies."
    static let unpinTab =
        "Move this tab back to a project. Nothing is killed while it is loaded."
    static let closePinnedTab =
        "Stop this tab's terminals. The pinned row stays dimmed so you can start it again."
    static let closeTab =
        "Close this tab and end its terminals."
    static let deleteFolder =
        "Remove the folder grouping. Projects inside are kept, ungrouped."
    static let separatePanes =
        "Move each pane into its own tab. Shells keep running."
    static let localFolder =
        "Open a folder as a project. If it is already in the sidebar, select it."
    static let remoteMachine =
        "Add an SSH project by host and directory."
    static let newFolder =
        "Create a named folder to group projects in the sidebar."

    static let newTab = "Open a new tab in this project."
    static let copyPath = "Copy this project's path to the clipboard."
    static let renameProject = "Rename this project in the sidebar."
    static let ungroupProject = "Take this project out of its folder."
    static let moveProjectToFolder = "Move this project into this folder."
    static let moveProjectUp = "Move this project up among its siblings."
    static let moveProjectDown = "Move this project down among its siblings."
    static let renameFolder = "Rename this folder."
    static let ungroupFolder = "Move this folder to the top level."
    static let nestFolder = "Nest this folder inside this folder."
    static let moveFolderUp = "Move this folder up among its siblings."
    static let moveFolderDown = "Move this folder down among its siblings."
    static let renameTab = "Rename this tab in the sidebar."
    static let moveTabUp = "Move this tab up in the list."
    static let moveTabDown = "Move this tab down in the list."
    static let moveTabToProject = "Move this tab into this project."
    static let unpinToProject = "Move this pinned tab into this project."
    static let movePinnedUp = "Move this pinned tab up in the list."
    static let movePinnedDown = "Move this pinned tab down in the list."
    static let deleteFolders =
        "Remove these folder groupings. Projects inside are kept, ungrouped."
    static let closeTabs = "Close these tabs and end their terminals."
    static let removeProjects =
        "Remove these projects from the sidebar and end their sessions. Layout files are kept."
    static let removeItems = "Remove the selected folders, projects, and tabs."
}
