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
}
