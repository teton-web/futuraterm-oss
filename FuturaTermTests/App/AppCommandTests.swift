import Foundation
@testable import FuturaTerm
import Testing

@MainActor
struct AppCommandTests {
    @Test
    func every_command_has_non_empty_help() {
        for command in AppCommand.allCases {
            #expect(
                !command.help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(command.rawValue) help is empty"
            )
        }
    }

    @Test
    func unload_and_remove_help_reuse_project_action_help_verbatim() {
        #expect(AppCommand.unloadProject.help == ProjectActionHelp.unload)
        #expect(AppCommand.removeProject.help == ProjectActionHelp.remove)
        #expect(
            AppCommand.unloadProject.help
                == "Stop this project's terminals but keep it in the sidebar. Select it again to restore the same tabs with new shells."
        )
        #expect(
            AppCommand.removeProject.help
                == "Remove this project from the sidebar and end its sessions. Saved layout files on disk are kept."
        )
    }

    @Test
    func close_tab_help_describes_the_whole_tab_not_one_pane() {
        #expect(AppCommand.closeTab.help == "Close the current tab and all of its panes.")
        #expect(AppCommand.closePane.help != AppCommand.closeTab.help)
    }

    @Test
    func manage_sessions_is_window_command_with_title_and_help() {
        #expect(AppCommand.manageSessions.rawValue == "manageSessions")
        #expect(AppCommand.manageSessions.title == "Sessions")
        #expect(
            AppCommand.manageSessions.help
                == "Show every local terminal session and whether it is open in a project."
        )
        #expect(AppCommand.manageSessions.category == .window)
        #expect(AppCommand.manageSessions.hotkeyAction == nil)
    }

    @Test
    func view_desktop_is_unbound_projects_command() {
        #expect(AppCommand.viewDesktop.rawValue == "viewDesktop")
        #expect(AppCommand.viewDesktop.title == "View Desktop")
        #expect(AppCommand.viewDesktop.title == ChromeDialogAccessibility.viewDesktop)
        #expect(
            AppCommand.viewDesktop.help
                == "Open a live view of this remote machine's screen."
        )
        #expect(AppCommand.viewDesktop.category == .projects)
        #expect(AppCommand.viewDesktop.hotkeyAction == nil)
    }

    @Test
    func view_desktop_action_nil_on_local_and_enabled_on_remote() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-\(UUID().uuidString).json")
        let storeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-\(UUID().uuidString).json")
        let filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: filesDir)
        )
        let store = ProjectStore(fileURL: storeTmp)
        let local = Project(name: "local", path: "/tmp/proj", sortOrder: 0)
        store.add(local)
        state.activeProjectID = local.id
        let localCtx = AppCommandContext(appState: state, projectStore: store)
        #expect(AppCommand.viewDesktop.action(in: localCtx) == nil)
        #expect(AppCommand.viewDesktop.paletteDisabledHint(in: localCtx) == DesktopView.notRemoteReason)

        let remote = Project(name: "box", path: "box.tailnet.ts.net:~", sortOrder: 1)
        store.add(remote)
        state.activeProjectID = remote.id
        let remoteCtx = AppCommandContext(appState: state, projectStore: store)
        #expect(AppCommand.viewDesktop.action(in: remoteCtx) != nil)
        #expect(AppCommand.viewDesktop.paletteDisabledHint(in: remoteCtx) == nil)
    }

    @Test
    func manage_environments_is_window_command_with_title_and_help() {
        #expect(AppCommand.manageEnvironments.rawValue == "manageEnvironments")
        #expect(AppCommand.manageEnvironments.title == "Environments")
        #expect(
            AppCommand.manageEnvironments.help
                == "Show local development servers listening on this Mac."
        )
        #expect(AppCommand.manageEnvironments.category == .window)
        #expect(AppCommand.manageEnvironments.hotkeyAction == nil)
    }
}
