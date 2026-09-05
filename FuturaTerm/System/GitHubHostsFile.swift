import Foundation
import Yams

/// GitHub CLI `hosts.yml` identity. Reads only the login (`user` / `users`
/// map keys) — never `oauth_token` or other secret fields.
enum GitHubHostsFile {
    struct Identity: Equatable, Hashable {
        var host: String
        var user: String
    }

    /// `GH_CONFIG_DIR/hosts.yml` when that env var is set and non-empty, else
    /// `~/.config/gh/hosts.yml` via `$HOME`-first `ProjectPath.currentHome`.
    static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = ProjectPath.currentHome
    ) -> URL {
        if let configDir = environment["GH_CONFIG_DIR"], !configDir.isEmpty {
            return URL(fileURLWithPath: configDir, isDirectory: true)
                .appendingPathComponent("hosts.yml")
        }
        return URL(fileURLWithPath: home + "/.config/gh/hosts.yml")
    }

    static func load(
        from url: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Identity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, environment: environment)
    }

    /// Host pick: `GH_HOST` if that key is in the file; else `github.com` if
    /// present; else the first remaining host (sorted). Login is the entry's
    /// `user:` string, or the first `users:` map key when `user` is missing.
    static func parse(_ data: Data, environment: [String: String] = [:]) -> Identity? {
        guard let yaml = String(data: data, encoding: .utf8),
              let node = try? Yams.compose(yaml: yaml),
              let mapping = node.mapping
        else { return nil }

        var entries: [(host: String, user: String?)] = []
        for (key, value) in mapping {
            guard let host = scalar(key) else { continue }
            entries.append((host, user(from: value)))
        }
        guard !entries.isEmpty else { return nil }

        let picked: String
        if let ghHost = environment["GH_HOST"], !ghHost.isEmpty,
           entries.contains(where: { $0.host == ghHost })
        {
            picked = ghHost
        } else if entries.contains(where: { $0.host == "github.com" }) {
            picked = "github.com"
        } else if let first = entries.map(\.host).min() {
            picked = first
        } else {
            return nil
        }

        guard let user = entries.first(where: { $0.host == picked })?.user,
              !user.isEmpty
        else { return nil }
        return Identity(host: picked, user: user)
    }

    static func avatarURL(host: String, user: String) -> URL? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !user.isEmpty else { return nil }
        if host == "github.com" {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "avatars.githubusercontent.com"
            components.path = "/" + user
            components.queryItems = [URLQueryItem(name: "s", value: "80")]
            return components.url
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/" + user + ".png"
        return components.url
    }

    static func avatarURL(for identity: Identity) -> URL? {
        avatarURL(host: identity.host, user: identity.user)
    }

    /// Top-level `user` wins. Otherwise the first `users:` key in YAML order.
    /// Values of `users` (where `oauth_token` lives) are never read.
    private static func user(from node: Node) -> String? {
        guard let mapping = node.mapping else { return nil }
        if let user = scalar(mapping["user"]), !user.isEmpty {
            return user
        }
        guard let users = mapping["users"]?.mapping else { return nil }
        for (key, _) in users {
            if let login = scalar(key), !login.isEmpty {
                return login
            }
        }
        return nil
    }

    private static func scalar(_ node: Node?) -> String? {
        guard let raw = node?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }
}
