@testable import FuturaTerm
import Testing

@MainActor
struct ChromeHelpTests {
    @Test
    func mandatory_copy_is_the_predecided_sentences() {
        #expect(
            ChromeHelp.newProject
                == "Add a local folder, a remote machine, or a sidebar folder."
        )
        #expect(
            ChromeHelp.projectRowMenu
                == "Apply or save layout, reorder, unload, or remove this project."
        )
        #expect(
            ChromeHelp.environments
                == "Show local development servers listening on this Mac."
        )
        #expect(ChromeHelp.viewDesktop == AppCommand.viewDesktop.help)
    }

    @Test
    func sidebar_chrome_has_display_icon_and_project_view_desktop() throws {
        let sidebar = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("FuturaTerm/Views/Sidebar.swift"),
            encoding: .utf8
        )
        #expect(sidebar.contains("viewDesktopButton()"))
        #expect(sidebar.contains("systemImage: \"display\""))
        #expect(sidebar.contains("Button(\"View Desktop\")"))
        #expect(sidebar.contains(".disabled(!project.isRemote)"))
        #expect(sidebar.contains(".disabled(activeRemoteProject == nil)"))
    }
}
