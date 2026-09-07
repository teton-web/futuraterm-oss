import Foundation
@testable import FuturaTerm
import Testing

struct MoonlightMacInstallTests {
    @Test
    func diskImageDownloadURL_picks_the_official_dmg_not_the_appimage() {
        let json = Data(
            """
            {"assets":[
              {"name":"Moonlight-9.9.9-x86_64.AppImage","browser_download_url":"https://example.com/appimage"},
              {"name":"Moonlight-9.9.9.dmg","browser_download_url":"https://example.com/Moonlight-9.9.9.dmg"},
              {"name":"MoonlightSetup-9.9.9.exe","browser_download_url":"https://example.com/exe"}
            ]}
            """.utf8
        )
        #expect(
            MoonlightMacInstall.diskImageDownloadURL(fromGitHubReleaseJSON: json)
                == URL(string: "https://example.com/Moonlight-9.9.9.dmg")
        )
    }

    @Test
    func diskImageDownloadURL_nil_without_a_dmg() {
        let json = Data(#"{"assets":[{"name":"notes.txt","browser_download_url":"https://x"}]}"#.utf8)
        #expect(MoonlightMacInstall.diskImageDownloadURL(fromGitHubReleaseJSON: json) == nil)
    }

    @Test
    func copyApp_installs_into_home_applications() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let volume = root.appendingPathComponent("vol", isDirectory: true)
        let dest = root.appendingPathComponent("Applications/Moonlight.app", isDirectory: true)
        try fm.createDirectory(
            at: volume.appendingPathComponent("Moonlight.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        try MoonlightMacInstall.copyApp(fromVolume: volume, to: dest, fileManager: fm)
        #expect(fm.fileExists(atPath: dest.path))
    }

    @Test
    func binaryURL_finds_homebrew_moonlight_qt() {
        let found = MoonlightMacInstall.binaryURL(
            pathEnv: "/usr/bin",
            fileExists: { $0 == "/opt/homebrew/bin/moonlight-qt" }
        )
        #expect(found?.path == "/opt/homebrew/bin/moonlight-qt")
    }

    @Test
    func applicationsMoonlightURL_is_under_home_applications() {
        let url = MoonlightMacInstall.applicationsMoonlightURL(home: "/Users/ada")
        #expect(url.path == "/Users/ada/Applications/Moonlight.app")
        #expect(MoonlightMacInstall.systemMoonlightURL().path == "/Applications/Moonlight.app")
    }
}
