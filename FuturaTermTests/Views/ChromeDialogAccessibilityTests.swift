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
        #expect(ChromeDialogAccessibility.viewDesktop == "View Desktop")
        #expect(
            ChromeDialogAccessibility.viewDesktopMissingMoonlight
                == DesktopView.moonlightMissingReason
        )
        #expect(ChromeDialogAccessibility.viewDesktopNotRemote == DesktopView.notRemoteReason)
        #expect(ChromeDialogAccessibility.tailscaleDevices == "Tailscale Devices")
        #expect(
            ChromeDialogAccessibility.tailscaleUnavailableNotInstalled
                == "Tailscale is not installed. Enter a host instead."
        )
        #expect(
            ChromeDialogAccessibility.tailscaleUnavailableNeedsLogin
                == "Tailscale is not logged in. Enter a host instead."
        )
        #expect(
            ChromeDialogAccessibility.tailscaleUnavailableStopped
                == "Tailscale is not running. Enter a host instead."
        )
        #expect(
            ChromeDialogAccessibility.tailscaleUnavailableError
                == "Couldn’t read Tailscale status. Enter a host instead."
        )
        #expect(ChromeDialogAccessibility.tailscaleNoDevices == "No other devices on this tailnet.")
        #expect(ChromeDialogAccessibility.enterHostManually == "Enter Host Manually")
        #expect(ChromeDialogAccessibility.chooseDirectory == "Choose Project Directory")
        #expect(ChromeDialogAccessibility.back == "Back")
        #expect(ChromeDialogAccessibility.openExisting == "Open Existing")
        #expect(ChromeDialogAccessibility.sessions == "Sessions")
        #expect(ChromeDialogAccessibility.environments == "Environments")
        #expect(ChromeDialogAccessibility.openInBrowser == "Open in Browser")
        #expect(ChromeDialogAccessibility.showInFuturaTerm == "Show in FuturaTerm")
        #expect(ChromeDialogAccessibility.couldNotOpenAddress == "Couldn’t open that address.")
        #expect(ChromeDialogAccessibility.newFolder == "New Folder")
        #expect(ChromeDialogAccessibility.newFolderName == "Name")
        #expect(ChromeDialogAccessibility.create == "Create")
        #expect(ChromeDialogAccessibility.add == "Add")
        #expect(ChromeDialogAccessibility.kill == "Kill")
        #expect(ChromeDialogAccessibility.openInFuturaTerm == "Open in FuturaTerm")
        #expect(ChromeDialogAccessibility.openInDefaultTerminal == "Open in Default Terminal")
        #expect(ChromeDialogAccessibility.zmxNotAvailable == "zmx is not available")
        #expect(ChromeDialogAccessibility.needsLocalProject == "Open a local project first.")
        #expect(ChromeDialogAccessibility.sessionNotFound == "Session not found.")
        #expect(ChromeDialogAccessibility.killSessionsTitle(count: 1) == "Kill Session?")
        #expect(ChromeDialogAccessibility.killSessionsTitle(count: 3) == "Kill 3 Sessions?")
        #expect(
            ChromeDialogAccessibility.killAttachedWarning
                == "Sessions open in FuturaTerm will close their panes."
        )
        #expect(
            ChromeDialogAccessibility.killSessionsMessage(
                names: ["a", "b"],
                includesAttached: false
            ) == "a\nb"
        )
        let nine = (1 ... 9).map { "s\($0)" }
        #expect(
            ChromeDialogAccessibility.killSessionsMessage(names: nine, includesAttached: true)
                == "s1\ns2\ns3\ns4\ns5\ns6\ns7\ns8\nand 1 more\n\(ChromeDialogAccessibility.killAttachedWarning)"
        )
        #expect(ChromeDialogAccessibility.killServerTitle(count: 1) == "Kill Server?")
        #expect(ChromeDialogAccessibility.killServerTitle(count: 3) == "Kill 3 Servers?")
        #expect(
            ChromeDialogAccessibility.killServerWarning
                == "The process listening on that port will receive SIGTERM."
        )
        #expect(
            ChromeDialogAccessibility.killServerMessage(lines: ["node · 3000", "vite · 5173"])
                == "node · 3000\nvite · 5173\n\(ChromeDialogAccessibility.killServerWarning)"
        )
        let nineServers = (1 ... 9).map { "cmd · \($0)" }
        let expectedServers = [
            "cmd · 1", "cmd · 2", "cmd · 3", "cmd · 4",
            "cmd · 5", "cmd · 6", "cmd · 7", "cmd · 8",
            "and 1 more",
            ChromeDialogAccessibility.killServerWarning,
        ].joined(separator: "\n")
        #expect(ChromeDialogAccessibility.killServerMessage(lines: nineServers) == expectedServers)
    }
}
