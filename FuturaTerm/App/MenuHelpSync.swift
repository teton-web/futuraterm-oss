import AppKit
import SwiftUI

/// Pins `NSMenuItem.toolTip` on SwiftUI `Menu` / `contextMenu` items.
///
/// SwiftUI `.help()` on a `Button` is the documented path; on macOS it is
/// not always copied onto the live item — the same drop `HotkeyMenuSync`
/// already patches on the menu bar. Context menus are not in
/// `NSApp.mainMenu`, so this observer applies a title→tooltip map to the
/// `NSMenu` that just began tracking. The menu bar is skipped: titles such
/// as "New Tab" and "Close Tab" overlap with `AppCommand.help`, whose copy
/// is deliberately different.
enum MenuHelpSync {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var helpByTitle: [String: String] = [:]
    nonisolated(unsafe) private static var observer: NSObjectProtocol?
    /// Cached so the tracking callback (nonisolated, main-queue) can skip
    /// the menu bar without reading `NSApp` off isolation.
    nonisolated(unsafe) private static var mainMenu: NSMenu?

    /// Last write wins for a title, so a pinned "Close Tab" does not leak
    /// onto the next normal tab menu (they never share an `NSMenu`).
    @MainActor
    static func merge(_ mapping: [String: String]) {
        mainMenu = NSApp.mainMenu
        ensureObserver()
        lock.lock()
        helpByTitle.merge(mapping) { _, new in new }
        lock.unlock()
    }

    /// Test seam: production walks the tracking menu; tests pass a throwaway.
    static func apply(_ mapping: [String: String], to menu: NSMenu) {
        for item in menu.items {
            if let tooltip = mapping[item.title] {
                item.toolTip = tooltip
            }
            if let submenu = item.submenu {
                apply(mapping, to: submenu)
            }
        }
    }

    /// Test seam: production applies `helpByTitle` to the tracking menu.
    static func applyRegisteredHelp(in menu: NSMenu) {
        lock.lock()
        let mapping = helpByTitle
        lock.unlock()
        apply(mapping, to: menu)
    }

    /// Test seam: drop accumulated titles so cases cannot leak across tests.
    static func reset() {
        lock.lock()
        helpByTitle.removeAll()
        lock.unlock()
    }

    @MainActor
    private static func ensureObserver() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let menu = note.object as? NSMenu else { return }
            applyRegisteredHelpSkippingMainMenu(menu)
        }
    }

    private static func applyRegisteredHelpSkippingMainMenu(_ menu: NSMenu) {
        if isInMainMenu(menu) { return }
        applyRegisteredHelp(in: menu)
    }

    private static func isInMainMenu(_ menu: NSMenu) -> Bool {
        let root = mainMenu
        var current: NSMenu? = menu
        while let currentMenu = current {
            if currentMenu === root { return true }
            current = currentMenu.supermenu
        }
        return false
    }
}

extension View {
    /// Native `.help` plus `NSMenuItem.toolTip` fallback. Registers during
    /// view construction so the map is populated before
    /// `NSMenu.didBeginTracking` — not in `onAppear`, which can lose the race.
    @MainActor
    func menuHelp(_ tooltip: String, titled title: String) -> some View {
        MenuHelpSync.merge([title: tooltip])
        return help(tooltip)
    }
}
