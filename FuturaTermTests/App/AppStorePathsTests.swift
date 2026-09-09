import Foundation
@testable import FuturaTerm
import Testing

struct AppStoreZmxDirTests {
    @Test
    func shortAppSupportUsesZmxSubdir() {
        let appSupport = URL(fileURLWithPath: "/short/support", isDirectory: true)
        let caches = URL(fileURLWithPath: "/short/caches", isDirectory: true)
        let dir = AppStoreZmxDir.url(appSupport: appSupport, caches: caches)
        #expect(dir.path == "/short/support/zmx")
        #expect(AppStoreZmxDir.fits(dir))
        #expect(ZmxSocketBudget.probe(env: ["ZMX_DIR": dir.path]) == nil)
    }

    @Test
    func overlongAppSupportFallsBackToCaches() {
        let long = "/" + String(repeating: "a", count: 80)
        let appSupport = URL(fileURLWithPath: long, isDirectory: true)
        let caches = URL(fileURLWithPath: "/c", isDirectory: true)
        let dir = AppStoreZmxDir.url(appSupport: appSupport, caches: caches)
        #expect(dir.path == "/c/zmx")
        #expect(ZmxSocketBudget.probe(env: ["ZMX_DIR": dir.path]) == nil)
    }

    @Test
    func overlongAppSupportAndCachesUsesHashedTemporary() {
        let long = "/" + String(repeating: "a", count: 80)
        let appSupport = URL(fileURLWithPath: long, isDirectory: true)
        let caches = URL(fileURLWithPath: long + "c", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/t", isDirectory: true)
        #expect(!AppStoreZmxDir.fits(appSupport.appendingPathComponent("zmx")))
        #expect(!AppStoreZmxDir.fits(caches.appendingPathComponent("zmx")))
        let dir = AppStoreZmxDir.url(appSupport: appSupport, caches: caches, temporary: temporary)
        #expect(dir.path == "/t/\(AppStoreZmxDir.shortName(for: appSupport))")
        #expect(ZmxSocketBudget.probe(env: ["ZMX_DIR": dir.path]) == nil)
    }

    @Test
    func overflowingContainerDoesNotUseGlobalTmp() {
        let long = "/" + String(repeating: "a", count: 80)
        let appSupport = URL(fileURLWithPath: long, isDirectory: true)
        let caches = URL(fileURLWithPath: long, isDirectory: true)
        let temporary = URL(fileURLWithPath: long, isDirectory: true)
        let dir = AppStoreZmxDir.url(appSupport: appSupport, caches: caches, temporary: temporary)
        #expect(dir.path != "/tmp/zmx-\(getuid())")
        #expect(!dir.path.hasPrefix("/tmp/zmx-"))
        #expect(dir.lastPathComponent == AppStoreZmxDir.shortName(for: appSupport))
    }

    @Test
    func realisticContainerPrefixPicksFittingEntitledDir() {
        let data =
            "/Users/davidsolheim/Library/Containers/com.davidsolheim.futuraterm/Data"
        let appSupport = URL(
            fileURLWithPath: data + "/Library/Application Support/FuturaTerm",
            isDirectory: true
        )
        let caches = URL(fileURLWithPath: data + "/Library/Caches", isDirectory: true)
        let temporary = URL(fileURLWithPath: data + "/tmp", isDirectory: true)
        #expect(!AppStoreZmxDir.fits(appSupport.appendingPathComponent("zmx")))
        #expect(!AppStoreZmxDir.fits(caches.appendingPathComponent("zmx")))
        let hashedTmp = temporary.appendingPathComponent(AppStoreZmxDir.shortName(for: appSupport))
        #expect(!AppStoreZmxDir.fits(hashedTmp))
        let config = AppStoreZmxDir.entitledConfigDirectory(home: "/Users/davidsolheim")
        let dir = AppStoreZmxDir.url(
            appSupport: appSupport,
            caches: caches,
            temporary: temporary,
            extraCandidates: [config]
        )
        #expect(AppStoreZmxDir.fits(dir))
        #expect(dir.path.hasPrefix(config.path))
        #expect(!dir.path.hasPrefix("/tmp/zmx-"))
        #expect(ZmxSocketBudget.probe(env: ["ZMX_DIR": dir.path]) == nil)
    }

    @Test
    func containerHomeStillPicksFittingEntitledRealHome() throws {
        let passwd = try #require(AppStoreZmxDir.unsandboxedHomeDirectory())
        let container = passwd + "/Library/Containers/com.davidsolheim.futuraterm/Data"
        let appSupport = URL(
            fileURLWithPath: container + "/Library/Application Support/FuturaTerm",
            isDirectory: true
        )
        let caches = URL(fileURLWithPath: container + "/Library/Caches", isDirectory: true)
        let temporary = URL(fileURLWithPath: container + "/tmp", isDirectory: true)
        #expect(!AppStoreZmxDir.fits(appSupport.appendingPathComponent("zmx")))
        #expect(!AppStoreZmxDir.fits(caches.appendingPathComponent("zmx")))
        let hashedTmp = temporary.appendingPathComponent(AppStoreZmxDir.shortName(for: appSupport))
        #expect(!AppStoreZmxDir.fits(hashedTmp))

        let containerEntitled = AppStoreZmxDir.entitledConfigDirectory(home: container)
        let containerHashed = containerEntitled.appendingPathComponent(
            AppStoreZmxDir.shortName(for: appSupport)
        )
        #expect(!AppStoreZmxDir.fits(containerHashed))

        let entitled = AppStoreZmxDir.entitledConfigDirectory()
        #expect(entitled.path.hasPrefix(passwd))
        #expect(!entitled.path.hasPrefix(container))
        let dir = AppStoreZmxDir.url(
            appSupport: appSupport,
            caches: caches,
            temporary: temporary,
            extraCandidates: [entitled]
        )
        #expect(AppStoreZmxDir.fits(dir))
        #expect(dir.path.hasPrefix(entitled.path))
        #expect(!dir.path.hasPrefix("/tmp/zmx-"))
        #expect(ZmxSocketBudget.probe(env: ["ZMX_DIR": dir.path]) == nil)
    }

    @Test
    func hashedNameIsStableForAPath() {
        let url = URL(fileURLWithPath: "/Users/x/Library/Application Support/FuturaTerm", isDirectory: true)
        let first = AppStoreZmxDir.shortName(for: url)
        let second = AppStoreZmxDir.shortName(for: url)
        #expect(first == second)
        #expect(first.count == 9)
        #expect(first.hasPrefix("z"))
    }
}

@MainActor
struct AppStoreZmxSourcePinTests {
    @Test
    func environmentSetupMentionsZmxDirOnlyUnderAppStore() throws {
        let text = try String(contentsOf: repoFile("FuturaTerm/App/EnvironmentSetup.swift"), encoding: .utf8)
        #expect(text.contains("#if APP_STORE"))
        #expect(text.contains("ZMX_DIR"))
        #expect(text.contains("pinAppStoreZmxDir"))
        #expect(text.contains("setenv(\"ZMX_DIR\""))
        #expect(text.contains("extraCandidates"))
        #expect(text.contains("entitledConfigDirectory"))
        let unguarded = text.replacingOccurrences(
            of: #"#if APP_STORE[\s\S]*?#endif"#,
            with: "",
            options: .regularExpression
        )
        #expect(!unguarded.contains("setenv(\"ZMX_DIR\""))
    }

    @Test
    func debugHostDoesNotExportZmxDirViaEnvironmentSetup() {
        #expect(AppDistribution.isAppStore == false)
        let appSupportZmx = FileStorage.appSupportDirectory().appendingPathComponent("zmx").path
        let current = ProcessInfo.processInfo.environment["ZMX_DIR"]
        #expect(current != appSupportZmx)
    }

    @Test
    func masEntitlementsStayMinimalAndOmitFda() throws {
        let text = try String(contentsOf: repoFile("FuturaTerm/FuturaTerm.mas.entitlements"), encoding: .utf8)
        #expect(text.contains("com.apple.security.app-sandbox"))
        #expect(text.contains("com.apple.security.network.client"))
        #expect(text.contains("com.apple.security.network.server"))
        #expect(text.contains("com.apple.security.files.user-selected.read-write"))
        #expect(text.contains("com.apple.security.files.bookmarks.app-scope"))
        #expect(text.contains("com.apple.security.files.downloads.read-write"))
        #expect(text.contains("/.config/futuraterm/"))
        #expect(text.contains("/.config/ghostty/"))
        #expect(text.contains("/Library/Application Support/com.mitchellh.ghostty/"))
        #expect(!text.contains("<string>.config/futuraterm/</string>"))
        #expect(!text.contains("<string>.config/ghostty/</string>"))
        #expect(!text.contains("<string>Library/Application Support/com.mitchellh.ghostty/</string>"))
        #expect(!text.contains("com.apple.security.files.all"))
        #expect(!text.contains("FullDiskAccess"))
        #expect(!text.contains("com.apple.security.device.camera"))
    }

    @Test
    func settingsHidesFdaBannerOnAppStoreCompileFlag() throws {
        let text = try String(contentsOf: repoFile("FuturaTerm/Settings/SettingsView.swift"), encoding: .utf8)
        #expect(text.contains("!AppDistribution.isAppStore"))
        #expect(text.contains("FullDiskAccessBanner()"))
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
