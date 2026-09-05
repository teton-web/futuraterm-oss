import AppKit
@testable import FuturaTerm
import Testing

@MainActor
struct HotkeyMenuSyncTests {
    @Test
    func applies_a_plain_modifier_shortcut() {
        let item = NSMenuItem()
        HotkeyMenuSync.apply("ctrl+]", to: item)
        #expect(item.keyEquivalent == "]")
        #expect(item.keyEquivalentModifierMask == [.control])
    }

    /// The reported bug: clearing a binding must strip the key equivalent, or
    /// AppKit keeps firing the command from the menu (menu dispatch runs
    /// before `KeyRouter`'s event monitor) until the app is relaunched.
    @Test
    func clearing_a_binding_strips_the_key_equivalent() {
        let item = NSMenuItem()
        HotkeyMenuSync.apply("ctrl+]", to: item)
        for cleared in ["disabled", "none", ""] {
            HotkeyMenuSync.apply(cleared, to: item)
            #expect(item.keyEquivalent.isEmpty)
            #expect(item.keyEquivalentModifierMask.isEmpty)
        }
    }

    @Test
    func maps_named_keys_to_their_appkit_characters() throws {
        let cases: [(String, String)] = try [
            ("cmd+return", "\r"),
            ("cmd+tab", "\t"),
            ("cmd+space", " "),
            ("cmd+escape", "\u{1b}"),
            ("cmd+left", String(#require(UnicodeScalar(NSLeftArrowFunctionKey)))),
            ("cmd+down", String(#require(UnicodeScalar(NSDownArrowFunctionKey)))),
        ]
        for (shortcut, expected) in cases {
            let item = NSMenuItem()
            HotkeyMenuSync.apply(shortcut, to: item)
            #expect(item.keyEquivalent == expected, "\(shortcut)")
            #expect(item.keyEquivalentModifierMask == [.command], "\(shortcut)")
        }
    }

    @Test
    func applies_multiple_modifiers() {
        let item = NSMenuItem()
        HotkeyMenuSync.apply("cmd+shift+d", to: item)
        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
    }

    /// An unparseable binding must clear rather than leave the previous
    /// shortcut in place — a stale equivalent is the exact failure mode here.
    @Test
    func an_unparseable_shortcut_clears_rather_than_leaving_a_stale_one() {
        let item = NSMenuItem()
        HotkeyMenuSync.apply("cmd+d", to: item)
        HotkeyMenuSync.apply("cmd+notakey", to: item)
        #expect(item.keyEquivalent.isEmpty)
        #expect(item.keyEquivalentModifierMask.isEmpty)
    }

    @Test
    func applyHelp_sets_tooltip_on_the_matching_submenu_item() {
        let main = NSMenu()
        let projectMenu = NSMenu()
        let unload = NSMenuItem(title: "Unload Project", action: nil, keyEquivalent: "")
        let other = NSMenuItem(title: "New Tab", action: nil, keyEquivalent: "")
        projectMenu.addItem(unload)
        projectMenu.addItem(other)
        let projectItem = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
        projectItem.submenu = projectMenu
        main.addItem(projectItem)
        HotkeyMenuSync.applyHelp(ProjectActionHelp.unload, titled: "Unload Project", in: main)
        #expect(unload.toolTip == ProjectActionHelp.unload)
        #expect(other.toolTip == nil)
    }

    @Test
    func applyHelp_sets_tooltip_for_a_hotkey_bound_command_title() {
        let main = NSMenu()
        let fileMenu = NSMenu()
        let closeTab = NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: "t")
        fileMenu.addItem(closeTab)
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        HotkeyMenuSync.applyHelp(AppCommand.closeTab.help, titled: "Close Tab", in: main)
        #expect(closeTab.toolTip == AppCommand.closeTab.help)
    }
}
