import Foundation
@testable import FuturaTerm
import Testing

@MainActor
struct AppDistributionTests {
    @Test
    func debug_host_is_not_app_store() {
        #expect(AppDistribution.isAppStore == false)
    }

    @Test
    func project_yml_pins_app_store_flag_and_mas_entitlements() throws {
        let yml = try String(contentsOf: repoFile("project.yml"), encoding: .utf8)
        #expect(yml.contains("APP_STORE"))
        #expect(yml.contains("FuturaTerm/FuturaTerm.mas.entitlements"))
        #expect(yml.contains("AppStore: release"))
        #expect(!yml.contains("MAC_APP_STORE"))
        #expect(yml.contains("link: false"))
        #expect(yml.contains("embed: false"))
        #expect(yml.contains("embed-sparkle.sh"))
        #expect(yml.contains("CONFIGURATION_BUILD_DIR"))
    }

    @Test
    func updater_stub_and_sparkle_import_are_compile_gated() throws {
        let updater = try String(contentsOf: repoFile("FuturaTerm/App/Updater.swift"), encoding: .utf8)
        #expect(updater.contains("#if APP_STORE"))
        #expect(updater.contains("canCheckForUpdates = false"))
        #expect(updater.contains("func checkForUpdates() {}"))
        #expect(updater.contains("automaticallyChecksForUpdates"))
        #expect(updater.contains("updateChannel"))
        #expect(updater.contains("updateAvailable"))
        let unguardedImport = updater.replacingOccurrences(
            of: #"#if !APP_STORE[\s\S]*?#endif"#,
            with: "",
            options: .regularExpression
        )
        #expect(!unguardedImport.contains("import Sparkle"))
    }

    @Test
    func settings_and_commands_hide_updates_on_app_store() throws {
        let settings = try String(contentsOf: repoFile("FuturaTerm/Settings/SettingsView.swift"), encoding: .utf8)
        #expect(settings.contains("sidebarPanes"))
        #expect(settings.contains("AppDistribution.isAppStore"))
        #expect(settings.contains("allCases.filter { $0 != .updates }"))
        let actions = try String(contentsOf: repoFile("FuturaTerm/App/AppCommandActions.swift"), encoding: .utf8)
        #expect(actions.contains("if AppDistribution.isAppStore { return nil }"))
        let callbacks = try String(contentsOf: repoFile("FuturaTerm/Ghostty/GhosttyCallbacks.swift"), encoding: .utf8)
        #expect(callbacks.contains("#if !APP_STORE"))
        #expect(callbacks.contains("GHOSTTY_ACTION_CHECK_FOR_UPDATES"))
        let unguarded = callbacks.replacingOccurrences(
            of: #"#if !APP_STORE[\s\S]*?#endif"#,
            with: "",
            options: .regularExpression
        )
        #expect(!unguarded.contains("Updater.shared"))
    }

    @Test
    func mas_entitlements_enable_app_sandbox() throws {
        let text = try String(contentsOf: repoFile("FuturaTerm/FuturaTerm.mas.entitlements"), encoding: .utf8)
        #expect(text.contains("com.apple.security.app-sandbox"))
        #expect(text.contains("com.apple.security.network.client"))
        #expect(text.contains("com.apple.security.files.bookmarks.app-scope"))
        #expect(text.contains("/.config/futuraterm/"))
    }

    private func repoFile(_ relative: String) throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        while true {
            let candidate = dir.appendingPathComponent("LICENSE")
            if fm.fileExists(atPath: candidate.path) {
                return dir.appendingPathComponent(relative)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path {
                throw TestError.missingRepoRoot
            }
            dir = parent
        }
    }

    private enum TestError: Error {
        case missingRepoRoot
    }
}
