import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "HotkeyMenuSync")

/// Keeps the menu bar's key equivalents in sync with the user's keybinds.
///
/// SwiftUI builds a `.commands` tree exactly once. Unlike an ordinary view
/// body it is not re-evaluated when observable state changes, so a
/// `.keyboardShortcut` reflects whatever the binding was at launch and nothing
/// in the view layer can update it — verified against a running app: after
/// clearing a binding the defaults value was `disabled` while the live
/// `NSMenuItem` still carried the old key equivalent, and it stayed stale
/// across menu opens.
///
/// That staleness was user-visible as a keybind that "didn't hot reload":
/// AppKit matches menu key equivalents *before* `KeyRouter`'s local event
/// monitor runs, so a cleared shortcut kept invoking its command from the
/// stale menu item even though `HotkeyRegistry` had already stopped matching
/// it. Only a relaunch rebuilt the menu.
///
/// The fix works one level down, on the real `NSMenuItem`s: `AppCommandMenuItem`
/// registers the title it renders, and `sync()` walks `NSApp.mainMenu` after a
/// rebind rewriting `keyEquivalent`/`keyEquivalentModifierMask` in place.
/// Unload/Remove also register help tags so `toolTip` is pinned on those items
/// even when SwiftUI `.help()` is dropped on the live menu.
@MainActor
enum HotkeyMenuSync {
    /// Rendered menu title → the action supplying its shortcut. Populated by
    /// `AppCommandMenuItem` as SwiftUI builds the menu. Titles are unique per
    /// item; two menu entries for the same command (e.g. "Open Project…" and
    /// "New Project…") register separately and both get synced.
    private static var actionsByTitle: [String: HotkeyAction] = [:]
    /// Rendered menu title → help tag. Unload/Remove only today (POR-340).
    private static var helpByTitle: [String: String] = [:]

    static func register(title: String, action: HotkeyAction) {
        actionsByTitle[title] = action
    }

    /// Pin `NSMenuItem.toolTip` for a menu-bar title. SwiftUI `.help()` on
    /// `Button` is the primary path; this is the AppKit fallback when that
    /// modifier is dropped on the live item.
    static func registerHelp(title: String, tooltip: String) {
        helpByTitle[title] = tooltip
        if let mainMenu = NSApp.mainMenu {
            applyHelp(tooltip, titled: title, in: mainMenu)
        }
    }

    /// Rewrite every registered menu item's key equivalent from the current
    /// bindings. Cheap (a few dozen items) and only runs on a rebind.
    static func sync() {
        guard let mainMenu = NSApp.mainMenu else { return }
        var synced = 0
        for (title, action) in actionsByTitle {
            guard let item = findItem(titled: title, in: mainMenu) else { continue }
            apply(HotkeyRegistry.selectedShortcutString(for: action), to: item)
            synced += 1
        }
        applyRegisteredHelp(in: mainMenu)
        logger.info("synced \(synced, privacy: .public) menu key equivalents")
    }

    /// Set `toolTip` on the item matching `title`. Test seam: production
    /// passes `NSApp.mainMenu`; tests pass a throwaway `NSMenu`.
    static func applyHelp(_ tooltip: String, titled title: String, in menu: NSMenu) {
        findItem(titled: title, in: menu)?.toolTip = tooltip
    }

    private static func applyRegisteredHelp(in menu: NSMenu) {
        for (title, tooltip) in helpByTitle {
            applyHelp(tooltip, titled: title, in: menu)
        }
    }

    /// Depth-first search for a menu item by exact title. AppKit nests the
    /// SwiftUI-authored items under their top-level menus, and the tree is
    /// small enough that a full walk per rebind is free.
    private static func findItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let found = findItem(titled: title, in: submenu) {
                return found
            }
        }
        return nil
    }

    /// Set (or clear) an item's key equivalent from a FuturaTerm shortcut string.
    /// An empty `keyEquivalent` is AppKit's "no shortcut" — that's what makes a
    /// cleared binding stop firing from the menu.
    static func apply(_ shortcut: String, to item: NSMenuItem) {
        guard let parsed = HotkeyRegistry.parseShortcut(shortcut),
              let key = keyEquivalentString(for: parsed.keyToken)
        else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = parsed.modifiers
    }

    /// FuturaTerm's key token → the single character AppKit wants. Named keys map
    /// to their control/function characters; everything else is already the
    /// literal character. Returns nil for a token AppKit can't express, which
    /// clears the shortcut rather than leaving a stale one behind.
    private static func keyEquivalentString(for token: String) -> String? {
        switch token {
        case "return",
             "enter": "\r"
        case "tab": "\t"
        case "space": " "
        case "escape": "\u{1b}"
        case "left": functionKey(NSLeftArrowFunctionKey)
        case "right": functionKey(NSRightArrowFunctionKey)
        case "up": functionKey(NSUpArrowFunctionKey)
        case "down": functionKey(NSDownArrowFunctionKey)
        default: token.count == 1 ? token : nil
        }
    }

    /// AppKit's arrow-key constants are in the Unicode private-use area and
    /// always form a valid scalar; the optional is an API artifact.
    private static func functionKey(_ code: Int) -> String? {
        UnicodeScalar(code).map(String.init)
    }
}
