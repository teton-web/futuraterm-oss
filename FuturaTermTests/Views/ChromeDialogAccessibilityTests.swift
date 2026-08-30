@testable import FuturaTerm
import Testing

struct ChromeDialogAccessibilityTests {
    @Test
    func command_palette_copy_is_filter_and_command_palette() {
        #expect(ChromeDialogAccessibility.commandPalette == "Command Palette")
        #expect(ChromeDialogAccessibility.filter == "Filter")
    }

    @Test
    func palette_row_value_omits_missing_and_blank_subtitles_and_trims() {
        #expect(ChromeDialogAccessibility.paletteRowValue(nil) == nil)
        #expect(ChromeDialogAccessibility.paletteRowValue("") == nil)
        #expect(ChromeDialogAccessibility.paletteRowValue("   ") == nil)
        #expect(
            ChromeDialogAccessibility.paletteRowValue("Close the focused pane")
                == "Close the focused pane"
        )
        #expect(ChromeDialogAccessibility.paletteRowValue("  Close pane  ") == "Close pane")
    }

    @Test
    func quit_dialog_label_includes_app_name_and_question_mark() {
        #expect(
            ChromeDialogAccessibility.quitDialogLabel(appName: "FuturaTerm")
                == "Quit FuturaTerm?"
        )
        #expect(
            ChromeDialogAccessibility.quitDialogLabel(appName: "FuturaTerm Debug")
                == "Quit FuturaTerm Debug?"
        )
        #expect(
            ChromeDialogAccessibility.quitWindowTitle(appName: "FuturaTerm")
                == "Quit FuturaTerm"
        )
        #expect(
            ChromeDialogAccessibility.quitWindowTitle(appName: "FuturaTerm Debug")
                == "Quit FuturaTerm Debug"
        )
        #expect(ChromeDialogAccessibility.quit == "Quit")
        #expect(ChromeDialogAccessibility.cancel == "Cancel")
        #expect(ChromeDialogAccessibility.runningProcesses == "Running processes")
    }

    @Test
    func quit_running_message_singular_and_plural() {
        #expect(
            ChromeDialogAccessibility.quitRunningMessage(count: 1)
                == "1 process is still running. Quit anyway?"
        )
        #expect(
            ChromeDialogAccessibility.quitRunningMessage(count: 2)
                == "2 processes are still running. Quit anyway?"
        )
        #expect(
            ChromeDialogAccessibility.quitRunningMessage(count: 0)
                == "0 processes are still running. Quit anyway?"
        )
    }

    @Test
    func quit_process_list_joins_project_and_process_names() {
        #expect(
            ChromeDialogAccessibility.quitProcessRow(projectName: "futuraterm", processName: "nvim")
                == "futuraterm, nvim"
        )
        let rows = [
            RunningProcessRow(projectName: "futuraterm", processName: "nvim"),
            RunningProcessRow(projectName: "lab", processName: "btop"),
        ]
        #expect(
            ChromeDialogAccessibility.quitProcessList(rows)
                == "futuraterm, nvim; lab, btop"
        )
        #expect(ChromeDialogAccessibility.quitProcessList([]).isEmpty)
    }

    @Test
    func sheet_and_folder_alert_titles_match_visible_chrome() {
        #expect(ChromeDialogAccessibility.newRemoteProject == "New Remote Project")
        #expect(ChromeDialogAccessibility.newFolder == "New Folder")
        #expect(ChromeDialogAccessibility.newFolderName == "Name")
        #expect(ChromeDialogAccessibility.create == "Create")
        #expect(ChromeDialogAccessibility.add == "Add")
    }
}
