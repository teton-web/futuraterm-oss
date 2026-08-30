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
    }
}
