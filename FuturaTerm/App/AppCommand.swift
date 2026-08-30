import Foundation

/// Single source of truth for every user-invokable action — both palette
/// commands and keyboard-bindable ones. Exposes a title-cased `title` (macOS
/// menu convention), a one-line `help` string, and a `category` so the
/// palette, File menu, and Settings can render the same list without
/// duplicated strings. The optional `hotkeyAction` link says whether a
/// command is rebindable; palette-only commands (like renaming the current
/// project) return nil.
enum AppCommand: String, CaseIterable, Identifiable {
    // Tabs
    case newTab
    case closePane
    case closeTab
    case renameTab
    case nextTab
    case previousTab
    case nextTabInProject
    case previousTabInProject
    case recentTab
    case separateAllPanes
    case pinTab
    case unpinTab
    // Panes
    case splitRight
    case splitDown
    case splitAuto
    case separateCurrentPane
    case zoomPane
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case nextPane
    case previousPane
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case copySessionID
    // Projects
    case openProject
    case newRemoteProject
    case renameProject
    case unloadProject
    case removeProject
    case replaceProjectPathWithCurrentDir
    case applyLayout
    case saveLayout
    case nextProject
    case previousProject
    // Window
    case toggleSidebar
    case closeWindow
    case toggleCommandPalette
    case reloadGhosttyConfig
    case toggleQuickTerminal
    case checkForUpdate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .closePane: "Close Pane"
        case .closeTab: "Close Tab"
        case .renameTab: "Rename Current Tab"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .nextTabInProject: "Next Tab in Project"
        case .previousTabInProject: "Previous Tab in Project"
        case .recentTab: "Recent Tab"
        case .separateAllPanes: "Separate All Panes"
        case .pinTab: "Pin Tab"
        case .unpinTab: "Unpin Tab"
        case .separateCurrentPane: "Separate Current Pane"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .splitAuto: "Split Automatically"
        case .zoomPane: "Zoom Pane"
        case .focusLeft: "Focus Left"
        case .focusRight: "Focus Right"
        case .focusUp: "Focus Up"
        case .focusDown: "Focus Down"
        case .nextPane: "Next Pane"
        case .previousPane: "Previous Pane"
        case .resizeLeft: "Resize Pane Left"
        case .resizeRight: "Resize Pane Right"
        case .resizeUp: "Resize Pane Up"
        case .resizeDown: "Resize Pane Down"
        case .copySessionID: "Copy Session ID"
        case .openProject: "Open Project"
        case .newRemoteProject: "New Remote Project"
        case .renameProject: "Rename Current Project"
        case .unloadProject: "Unload Current Project"
        case .removeProject: "Remove Current Project"
        case .replaceProjectPathWithCurrentDir: "Replace Project Path with Current Directory"
        case .applyLayout: "Apply Layout"
        case .saveLayout: "Save Layout"
        case .nextProject: "Next Project"
        case .previousProject: "Previous Project"
        case .toggleSidebar: "Toggle Sidebar"
        case .closeWindow: "Close Window"
        case .toggleCommandPalette: "Command Palette"
        case .reloadGhosttyConfig: "Reload Ghostty Config"
        case .toggleQuickTerminal: "Toggle Quick Terminal"
        case .checkForUpdate: "Check for Update"
        }
    }

    /// One-sentence hover help for menus, the palette, and Keymaps.
    /// Explains the action, not its shortcut. Unload/Remove reuse
    /// `ProjectActionHelp` verbatim so those three surfaces cannot drift.
    var help: String {
        switch self {
        case .newTab:
            "Open a new tab in the current project."
        case .closePane:
            "Close the focused pane. Closing the last pane of a tab also closes the tab."
        case .closeTab:
            "Close the current tab and all of its panes."
        case .renameTab:
            "Rename the current tab in the sidebar."
        case .nextTab:
            "Switch to the next tab across every project, including pinned tabs."
        case .previousTab:
            "Switch to the previous tab across every project, including pinned tabs."
        case .nextTabInProject:
            "Switch to the next tab in the current project."
        case .previousTabInProject:
            "Switch to the previous tab in the current project."
        case .recentTab:
            "Switch back to the most recently used tab in this project."
        case .separateAllPanes:
            "Move every pane in this tab into its own tab."
        case .pinTab:
            "Pin this tab so it stays running above the project list."
        case .unpinTab:
            "Unpin this tab and move it back to its project."
        case .splitRight:
            "Split the focused pane horizontally, opening a new pane to the right."
        case .splitDown:
            "Split the focused pane vertically, opening a new pane below."
        case .splitAuto:
            "Split the focused pane in the direction that best fits its size."
        case .separateCurrentPane:
            "Move the focused pane into its own tab."
        case .zoomPane:
            "Expand the focused pane to fill the tab, or restore the previous split."
        case .focusLeft:
            "Move focus to the pane on the left."
        case .focusRight:
            "Move focus to the pane on the right."
        case .focusUp:
            "Move focus to the pane above."
        case .focusDown:
            "Move focus to the pane below."
        case .nextPane:
            "Cycle focus to the next pane in this tab."
        case .previousPane:
            "Cycle focus to the previous pane in this tab."
        case .resizeLeft:
            "Grow or shrink the focused pane toward the left."
        case .resizeRight:
            "Grow or shrink the focused pane toward the right."
        case .resizeUp:
            "Grow or shrink the focused pane toward the top."
        case .resizeDown:
            "Grow or shrink the focused pane toward the bottom."
        case .copySessionID:
            "Copy the focused pane's session name to the clipboard."
        case .openProject:
            "Open a local folder as a project, or select it if it is already in the sidebar."
        case .newRemoteProject:
            "Add a project that runs on a remote machine over SSH."
        case .renameProject:
            "Rename the current project in the sidebar."
        case .unloadProject:
            ProjectActionHelp.unload
        case .removeProject:
            ProjectActionHelp.remove
        case .replaceProjectPathWithCurrentDir:
            "Set this project's folder to the current pane's working directory."
        case .applyLayout:
            "Apply this project's saved layout, matching live panes where possible."
        case .saveLayout:
            "Save this project's current tabs and panes as a layout file."
        case .nextProject:
            "Switch to the next project in the sidebar."
        case .previousProject:
            "Switch to the previous project in the sidebar."
        case .toggleSidebar:
            "Show or hide the sidebar."
        case .closeWindow:
            "Hide the window without quitting. Terminal sessions keep running."
        case .toggleCommandPalette:
            "Open or close the command palette."
        case .reloadGhosttyConfig:
            "Reload Ghostty configuration without restarting."
        case .toggleQuickTerminal:
            "Show or hide the quick terminal overlay."
        case .checkForUpdate:
            "Check whether a newer version of FuturaTerm is available."
        }
    }

    var category: Category {
        switch self {
        case .newTab,
             .closePane,
             .closeTab,
             .renameTab,
             .nextTab,
             .previousTab,
             .nextTabInProject,
             .previousTabInProject,
             .recentTab,
             .separateAllPanes,
             .pinTab,
             .unpinTab: .tabs
        case .splitRight,
             .splitDown,
             .splitAuto,
             .separateCurrentPane,
             .zoomPane,
             .focusLeft,
             .focusRight,
             .focusUp,
             .focusDown,
             .nextPane,
             .previousPane,
             .resizeLeft,
             .resizeRight,
             .resizeUp,
             .resizeDown,
             .copySessionID: .panes
        case .openProject,
             .newRemoteProject,
             .renameProject,
             .unloadProject,
             .removeProject,
             .replaceProjectPathWithCurrentDir,
             .applyLayout,
             .saveLayout,
             .nextProject,
             .previousProject: .projects
        case .toggleSidebar,
             .closeWindow,
             .toggleCommandPalette: .window
        case .reloadGhosttyConfig,
             .toggleQuickTerminal,
             .checkForUpdate: .other
        }
    }

    /// The keyboard-binding identity for this command, if any. Commands
    /// without a hotkey are palette-only.
    var hotkeyAction: HotkeyAction? {
        switch self {
        case .newTab: .newTab
        case .closePane: .closePane
        case .closeTab: .closeTab
        case .nextTab: .nextGlobalTab
        case .previousTab: .previousGlobalTab
        case .nextTabInProject: .nextTabInProject
        case .previousTabInProject: .previousTabInProject
        case .recentTab: .recentTab
        case .separateAllPanes: .separateAllPanes
        case .pinTab: .pinTab
        case .unpinTab: .unpinTab
        case .splitRight: .splitRight
        case .splitDown: .splitDown
        case .splitAuto: .splitAuto
        case .separateCurrentPane: .separateCurrentPane
        case .zoomPane: .zoomPane
        case .focusLeft: .focusPaneLeft
        case .focusRight: .focusPaneRight
        case .focusUp: .focusPaneUp
        case .focusDown: .focusPaneDown
        case .nextPane: .nextPane
        case .previousPane: .previousPane
        case .resizeLeft: .resizePaneLeft
        case .resizeRight: .resizePaneRight
        case .resizeUp: .resizePaneUp
        case .resizeDown: .resizePaneDown
        case .openProject: .openProject
        case .nextProject: .nextProject
        case .previousProject: .previousProject
        case .toggleSidebar: .toggleSidebar
        case .closeWindow: .closeWindow
        case .toggleCommandPalette: .toggleCommandPalette
        case .reloadGhosttyConfig: .reloadGhosttyConfig
        case .toggleQuickTerminal: .toggleQuickTerminal
        case .renameTab: .renameTab
        case .renameProject: .renameProject
        case .copySessionID: .copySessionID
        case .applyLayout: .applyLayout
        case .saveLayout: .saveLayout
        case .newRemoteProject,
             .unloadProject,
             .removeProject,
             .replaceProjectPathWithCurrentDir,
             .checkForUpdate: nil
        }
    }

    enum Category: String {
        case tabs = "Tabs"
        case panes = "Panes"
        case projects = "Projects"
        case window = "Window"
        case other = "Other"
    }
}

extension HotkeyAction {
    /// Memoized reverse map: `HotkeyAction` → the `AppCommand` that owns it.
    /// Built once instead of an O(n) `allCases` scan per lookup (called per
    /// action per Settings/palette render).
    private static let commandByAction: [HotkeyAction: AppCommand] = Dictionary(
        AppCommand.allCases.compactMap { command in
            command.hotkeyAction.map { ($0, command) }
        },
        uniquingKeysWith: { first, _ in first }
    )

    /// Reverse lookup: the AppCommand that owns this binding. Every
    /// `HotkeyAction` is linked to exactly one `AppCommand`, so a miss is a
    /// construction error (a new action added without its command) — trap in
    /// debug rather than silently mis-titling it as "New Tab".
    var appCommand: AppCommand {
        if let command = Self.commandByAction[self] { return command }
        assertionFailure("HotkeyAction \(rawValue) has no owning AppCommand")
        return .newTab
    }
}
