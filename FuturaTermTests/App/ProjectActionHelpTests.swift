@testable import FuturaTerm
import Testing

@MainActor
struct ProjectActionHelpTests {
    @Test
    func unload_and_remove_copy_is_the_predecided_sentences() {
        #expect(
            ProjectActionHelp.unload
                == "Stop this project's terminals but keep it in the sidebar. Select it again to restore the same tabs with new shells."
        )
        #expect(
            ProjectActionHelp.remove
                == "Remove this project from the sidebar and end its sessions. Saved layout files on disk are kept."
        )
    }

    @Test
    func only_unload_and_remove_commands_have_project_action_help() {
        #expect(ProjectActionHelp.help(for: .unloadProject) == ProjectActionHelp.unload)
        #expect(ProjectActionHelp.help(for: .removeProject) == ProjectActionHelp.remove)
        for command in AppCommand.allCases
            where command != .unloadProject && command != .removeProject
        {
            #expect(ProjectActionHelp.help(for: command) == nil)
        }
    }
}
