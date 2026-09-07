import AppKit
@testable import FuturaTerm
import Testing

@Suite(.serialized)
@MainActor
struct SidebarMenuHelpTests {
    @Test
    func mandatory_copy_is_the_predecided_sentences() {
        #expect(
            SidebarMenuHelp.pinTab
                == "Keep this tab above projects. It restores its layout even after the session dies."
        )
        #expect(
            SidebarMenuHelp.unpinTab
                == "Move this tab back to a project. Nothing is killed while it is loaded."
        )
        #expect(
            SidebarMenuHelp.closePinnedTab
                == "Stop this tab's terminals. The pinned row stays dimmed so you can start it again."
        )
        #expect(
            SidebarMenuHelp.closeTab
                == "Close this tab and end its terminals."
        )
        #expect(
            SidebarMenuHelp.deleteFolder
                == "Remove the folder grouping. Projects inside are kept, ungrouped."
        )
        #expect(
            SidebarMenuHelp.separatePanes
                == "Move each pane into its own tab. Shells keep running."
        )
        #expect(
            SidebarMenuHelp.localFolder
                == "Open a folder as a project. If it is already in the sidebar, select it."
        )
        #expect(
            SidebarMenuHelp.remoteMachine
                == "Pick a Tailscale device or enter an SSH host and directory."
        )
        #expect(
            SidebarMenuHelp.newFolder
                == "Create a named folder to group projects in the sidebar."
        )
    }

    @Test
    func close_tab_copy_differs_for_pinned_vs_normal() {
        #expect(SidebarMenuHelp.closePinnedTab != SidebarMenuHelp.closeTab)
        #expect(SidebarMenuHelp.closePinnedTab != AppCommand.closeTab.help)
        #expect(SidebarMenuHelp.pinTab != AppCommand.pinTab.help)
        #expect(SidebarMenuHelp.unpinTab != AppCommand.unpinTab.help)
    }

    @Test
    func apply_sets_tooltips_on_matching_items_including_submenus() {
        let menu = NSMenu()
        let pin = NSMenuItem(title: "Pin Tab", action: nil, keyEquivalent: "")
        let close = NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: "")
        let other = NSMenuItem(title: "Something Else", action: nil, keyEquivalent: "")
        menu.addItem(pin)
        menu.addItem(close)
        menu.addItem(other)
        let move = NSMenu()
        let dest = NSMenuItem(title: "Docs", action: nil, keyEquivalent: "")
        move.addItem(dest)
        let moveItem = NSMenuItem(title: "Move to Project", action: nil, keyEquivalent: "")
        moveItem.submenu = move
        menu.addItem(moveItem)

        MenuHelpSync.apply(
            [
                "Pin Tab": SidebarMenuHelp.pinTab,
                "Close Tab": SidebarMenuHelp.closeTab,
                "Docs": SidebarMenuHelp.moveTabToProject,
            ],
            to: menu
        )
        #expect(pin.toolTip == SidebarMenuHelp.pinTab)
        #expect(close.toolTip == SidebarMenuHelp.closeTab)
        #expect(other.toolTip == nil)
        #expect(dest.toolTip == SidebarMenuHelp.moveTabToProject)
        #expect(moveItem.toolTip == nil)
    }

    @Test
    func merge_last_write_wins_for_close_tab() {
        MenuHelpSync.reset()
        defer { MenuHelpSync.reset() }
        MenuHelpSync.merge(["Close Tab": SidebarMenuHelp.closeTab])
        MenuHelpSync.merge(["Close Tab": SidebarMenuHelp.closePinnedTab])
        let menu = NSMenu()
        let close = NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: "")
        menu.addItem(close)
        MenuHelpSync.applyRegisteredHelp(in: menu)
        #expect(close.toolTip == SidebarMenuHelp.closePinnedTab)
    }

    @Test
    func tracking_notification_applies_registered_help() async {
        MenuHelpSync.reset()
        defer { MenuHelpSync.reset() }
        MenuHelpSync.merge(["Pin Tab": SidebarMenuHelp.pinTab])
        let menu = NSMenu()
        let pin = NSMenuItem(title: "Pin Tab", action: nil, keyEquivalent: "")
        menu.addItem(pin)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        for _ in 0 ..< 20 where pin.toolTip == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(pin.toolTip == SidebarMenuHelp.pinTab)
    }
}
