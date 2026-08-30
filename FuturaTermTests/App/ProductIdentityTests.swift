import Foundation
@testable import FuturaTerm
import Testing

/// Pins shipped product identity. These values are the literals runtime
/// helpers actually use — not a parallel copy of the desired strings.
@MainActor
struct ProductIdentityTests {
    @Test
    func zmx_session_names_use_the_futuraterm_prefix() throws {
        #expect(ZmxSessionName.prefix == "futuraterm-")
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let name = ZmxSessionName.make(projectName: "api", paneSessionID: id)
        #expect(name.hasPrefix(ZmxSessionName.prefix))
        #expect(name.hasPrefix("futuraterm-"))
        #expect(name == "futuraterm-api-aaaaaaaabbbb")
    }

    @Test
    func fallback_bundle_id_and_display_name_are_futuraterm() {
        // Hosted tests load FuturaTerm.app; AppInfo reads those Info.plist
        // keys. Both flavors must still be FuturaTerm.
        #expect(appBundleID == "com.davidsolheim.futuraterm.debug"
            || appBundleID == "com.davidsolheim.futuraterm")
        #expect(appDisplayName == "FuturaTerm Debug" || appDisplayName == "FuturaTerm")
    }

    @Test
    func about_and_settings_version_include_real_git_commit() {
        let withCommit = AppVersion.info(
            shortVersion: "0.0.0",
            buildVersion: "0.0.0.9999",
            gitCommit: "c5b5129"
        )
        #expect(AppVersion.displayString(from: withCommit) == "0.0.0 (c5b5129)")
        #expect(AppVersion.aboutBuildString(from: withCommit) == "c5b5129")

        let placeholder = AppVersion.info(
            shortVersion: "0.0.0",
            buildVersion: "0.0.0",
            gitCommit: AppVersion.gitCommitPlaceholder
        )
        #expect(AppVersion.displayString(from: placeholder) == "0.0.0")
        #expect(AppVersion.aboutBuildString(from: placeholder) == nil)

        let buildOnly = AppVersion.info(
            shortVersion: "0.0.0",
            buildVersion: "0.0.0.9999",
            gitCommit: nil
        )
        #expect(AppVersion.displayString(from: buildOnly) == "0.0.0")
        #expect(AppVersion.aboutBuildString(from: buildOnly) == "0.0.0.9999")
    }

    @Test
    func app_registers_the_futuraterm_url_scheme() {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        #expect(schemes.contains("futuraterm"))
    }

    @Test
    func control_cli_command_name_is_futuraterm() {
        #expect(ControlProtocol.cliCommandName == "futuraterm")
        #expect(EnvironmentSetup.bundledCLIBinaryName == "futuraterm")
        #expect(EnvironmentSetup.bundledCLIBinaryName == ControlProtocol.cliCommandName)
    }

    @Test
    func project_yaml_lives_under_config_futuraterm() {
        let dir = ProjectFileStore.defaultDirectory()
        #expect(dir.path.contains("/.config/futuraterm/projects"))
        #expect(dir.path.contains(".config/futuraterm"))
    }

    @Test
    func remote_diagnostics_use_the_futuraterm_cli_prefix() {
        let remote = ProjectPath.remote(user: nil, host: "devbox", directory: "~/dev/api")
        let cmd = RemoteSpawn.paneCommand(remote: remote, sessionName: "futuraterm-api-abc123")
        #expect(cmd?.contains("futuraterm: zmx not found") == true)
        #expect(cmd?.contains("macterm: zmx not found") == false)
    }

    @Test
    func license_is_mit_and_credits_upstream() throws {
        let url = try #require(Self.repoFile("LICENSE"), "LICENSE not found walking up from #filePath")
        let license = try String(contentsOf: url, encoding: .utf8)
        #expect(license.contains("MIT License"))
        #expect(license.contains("Copyright (c) 2026 FuturaTerm"))
        #expect(license.contains("Copyright (c) 2026 Macterm"))
        #expect(license.contains("Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors"))
        #expect(license.contains("Copyright (c) 2025 Eric Bower"))
        #expect(!license.contains("thdxg"))
    }

    @Test
    func readme_credits_macterm_without_origin_links() throws {
        let url = try #require(Self.repoFile("README.md"), "README.md not found walking up from #filePath")
        let readme = try String(contentsOf: url, encoding: .utf8)
        #expect(readme.contains("FuturaTerm"))
        #expect(readme.contains("https://github.com/davidsolheim/futuraterm.git"))
        #expect(readme.contains("Portions derived from MacTerm, MIT, Copyright (c) 2026 Macterm"))
        #expect(!readme.contains("thdxg"))
        #expect(!readme.contains("ORIGIN.md"))
        #expect(!readme.contains("screenshot.png"))
    }

    /// Walk parent directories of this source file until `LICENSE` marks the
    /// repo root. Returns nil on a layout that isn't a checkout.
    private static func repoFile(_ name: String) -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent("LICENSE").path) {
                return dir.appendingPathComponent(name)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }
}
