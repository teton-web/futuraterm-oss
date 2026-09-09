import Foundation
@testable import FuturaTerm
import Testing

struct GitHubHostsFileTests {
    private let dummyToken = "dummy-oauth-token-never-copy"

    @Test
    func github_dot_com_user_and_public_avatar_url() throws {
        let yaml = """
        github.com:
            user: octocat
            oauth_token: \(dummyToken)
        """
        let identity = try #require(GitHubHostsFile.parse(Data(yaml.utf8)))
        #expect(identity.host == "github.com")
        #expect(identity.user == "octocat")
        assertNoToken(identity)
        let url = try #require(GitHubHostsFile.avatarURL(for: identity))
        #expect(url.scheme == "https")
        #expect(url.host == "avatars.githubusercontent.com")
        #expect(url.path == "/octocat")
        #expect(url.query == "s=80")
        #expect(url.absoluteString.contains("octocat"))
        #expect(url.absoluteString.contains("avatars.githubusercontent.com"))
    }

    @Test
    func enterprise_host_uses_png_path() throws {
        let yaml = """
        git.example.com:
            user: octocat
            oauth_token: \(dummyToken)
        """
        let identity = try #require(GitHubHostsFile.parse(Data(yaml.utf8)))
        #expect(identity.host == "git.example.com")
        #expect(identity.user == "octocat")
        assertNoToken(identity)
        let url = try #require(GitHubHostsFile.avatarURL(host: "git.example.com", user: "octocat"))
        #expect(url.absoluteString == "https://git.example.com/octocat.png")
    }

    @Test
    func gh_host_wins_when_present_in_file() throws {
        let yaml = """
        github.com:
            user: octocat
            oauth_token: \(dummyToken)
        git.example.com:
            user: hubot
            oauth_token: \(dummyToken)
        """
        let identity = try #require(
            GitHubHostsFile.parse(Data(yaml.utf8), environment: ["GH_HOST": "git.example.com"])
        )
        #expect(identity.host == "git.example.com")
        #expect(identity.user == "hubot")
        assertNoToken(identity)
        let url = try #require(GitHubHostsFile.avatarURL(for: identity))
        #expect(url.absoluteString == "https://git.example.com/hubot.png")
        #expect(url.host != "avatars.githubusercontent.com")
    }

    @Test
    func github_dot_com_wins_without_gh_host() throws {
        let yaml = """
        git.example.com:
            user: hubot
        github.com:
            user: octocat
        """
        let identity = try #require(GitHubHostsFile.parse(Data(yaml.utf8)))
        #expect(identity.host == "github.com")
        #expect(identity.user == "octocat")
    }

    @Test
    func missing_file_is_nil() {
        let url = URL(fileURLWithPath: "/tmp/futuraterm-missing-gh-hosts-\(UUID().uuidString).yml")
        #expect(GitHubHostsFile.load(from: url, environment: [:]) == nil)
    }

    @Test
    func empty_user_is_nil() {
        let yaml = """
        github.com:
            user: ""
            oauth_token: \(dummyToken)
        """
        #expect(GitHubHostsFile.parse(Data(yaml.utf8)) == nil)
    }

    @Test
    func missing_user_is_nil() {
        let yaml = """
        github.com:
            git_protocol: https
        """
        #expect(GitHubHostsFile.parse(Data(yaml.utf8)) == nil)
    }

    @Test
    func users_map_fallback_without_top_level_user() throws {
        let yaml = """
        github.com:
            users:
                octocat:
                    oauth_token: \(dummyToken)
        """
        let identity = try #require(GitHubHostsFile.parse(Data(yaml.utf8)))
        #expect(identity.host == "github.com")
        #expect(identity.user == "octocat")
        assertNoToken(identity)
    }

    @Test
    func top_level_user_wins_over_users_map() throws {
        let yaml = """
        github.com:
            user: octocat
            users:
                otherlogin:
                    oauth_token: \(dummyToken)
        """
        let identity = try #require(GitHubHostsFile.parse(Data(yaml.utf8)))
        #expect(identity.user == "octocat")
        assertNoToken(identity)
    }

    @Test
    func users_map_uses_first_yaml_key() throws {
        let yaml = """
        github.com:
            users:
                zebra:
                    oauth_token: \(dummyToken)
                alpha:
                    oauth_token: \(dummyToken)
        """
        let identity = try #require(GitHubHostsFile.parse(Data(yaml.utf8)))
        #expect(identity.user == "zebra")
        assertNoToken(identity)
    }

    @Test
    func first_remaining_host_is_sorted_when_github_absent() throws {
        let yaml = """
        zeta.example.com:
            user: zed
        alpha.example.com:
            user: al
        """
        let identity = try #require(GitHubHostsFile.parse(Data(yaml.utf8)))
        #expect(identity.host == "alpha.example.com")
        #expect(identity.user == "al")
    }

    @Test
    func gh_host_not_in_file_falls_through_to_github() throws {
        let yaml = """
        github.com:
            user: octocat
        git.example.com:
            user: hubot
        """
        let identity = try #require(
            GitHubHostsFile.parse(Data(yaml.utf8), environment: ["GH_HOST": "missing.example.com"])
        )
        #expect(identity.host == "github.com")
        #expect(identity.user == "octocat")
    }

    @Test
    func empty_gh_host_falls_through_to_github() throws {
        let yaml = """
        github.com:
            user: octocat
        git.example.com:
            user: hubot
        """
        let identity = try #require(
            GitHubHostsFile.parse(Data(yaml.utf8), environment: ["GH_HOST": ""])
        )
        #expect(identity.host == "github.com")
    }

    @Test
    func invalid_yaml_is_nil() {
        #expect(GitHubHostsFile.parse(Data(":::::".utf8)) == nil)
    }

    @Test
    func gh_config_dir_overrides_home_path() {
        let url = GitHubHostsFile.url(
            environment: ["GH_CONFIG_DIR": "/tmp/dummy-gh-config"],
            home: "/Users/nobody"
        )
        #expect(url.path == "/tmp/dummy-gh-config/hosts.yml")
    }

    @Test
    func empty_gh_config_dir_uses_home_config_gh() {
        let url = GitHubHostsFile.url(
            environment: ["GH_CONFIG_DIR": ""],
            home: "/Users/nobody"
        )
        #expect(url.path == "/Users/nobody/.config/gh/hosts.yml")
    }

    @Test
    func default_path_is_home_config_gh() {
        let url = GitHubHostsFile.url(environment: [:], home: "/Users/nobody")
        #expect(url.path == "/Users/nobody/.config/gh/hosts.yml")
    }

    @Test
    func load_reads_temp_file() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gh-hosts-\(UUID().uuidString).yml")
        let yaml = """
        github.com:
            user: octocat
            oauth_token: \(dummyToken)
        """
        try Data(yaml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let identity = try #require(GitHubHostsFile.load(from: url, environment: [:]))
        #expect(identity.user == "octocat")
        assertNoToken(identity)
    }

    private func assertNoToken(_ identity: GitHubHostsFile.Identity) {
        #expect(!String(describing: identity).contains(dummyToken))
        #expect(identity.user != dummyToken)
        #expect(!identity.host.contains(dummyToken))
    }
}
