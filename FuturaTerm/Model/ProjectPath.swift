import Foundation

/// Where a project lives: a local directory, or a directory on a remote host
/// reached over SSH. Parsed from a single scp-style string — the `path:` of a
/// central project file (and, in a later stage, `Project.path`):
///
///     /Users/me/dev/api        → local
///     ~/dev/api                → local
///     devbox:~/dev/api         → remote (host from ~/.ssh/config)
///     deploy@10.0.0.5:/srv/app → remote with explicit user
///
/// The grammar is scp's: a colon *before the first slash* marks a remote
/// `[user@]host:dir`; anything absolute or `~`-prefixed is local. Relative
/// local paths are invalid (there's no cwd to resolve them against), as are
/// empty host/dir parts. Port and identity aren't expressible here by design —
/// use an ssh-config alias for those. IPv6 literals (`[::1]:dir`) aren't
/// supported; alias them in ssh config too.
enum ProjectPath: Equatable {
    case local(String)
    case remote(user: String?, host: String, directory: String)

    /// Parse an scp-style path string. Returns nil for anything that is
    /// neither a valid local path (absolute or `~`-prefixed) nor a well-formed
    /// remote spec.
    static func parse(_ raw: String) -> ProjectPath? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // scp rule: a colon before the first slash → remote spec.
        if let colon = trimmed.firstIndex(of: ":"),
           !trimmed[..<colon].contains("/")
        {
            let userHost = trimmed[..<colon]
            let directory = String(trimmed[trimmed.index(after: colon)...])
            guard !directory.isEmpty else { return nil }

            // `user@host` splits at the LAST `@` (usernames may contain `@`
            // in principle; hosts never do). A host starting with `~` is
            // rejected: scp would accept it, but `~foo:bar` is far likelier a
            // mistyped local path than a host literally named `~foo`.
            if let at = userHost.lastIndex(of: "@") {
                let user = String(userHost[..<at])
                let host = String(userHost[userHost.index(after: at)...])
                guard !user.isEmpty, !host.isEmpty, !host.hasPrefix("~") else { return nil }
                return .remote(user: user, host: host, directory: directory)
            }
            guard !userHost.isEmpty, !userHost.hasPrefix("~") else { return nil }
            return .remote(user: nil, host: String(userHost), directory: directory)
        }

        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
        return .local(trimmed)
    }

    /// The user's home directory, `$HOME`-first. `NSHomeDirectory()` and
    /// `expandingTildeInPath` resolve via the user record and IGNORE the env
    /// var, which would defeat the benchmark harness's throwaway-home
    /// isolation; the login session sets `$HOME` for normal launches, so
    /// env-first behaves identically outside the harness.
    static var currentHome: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return home
        }
        return NSHomeDirectory()
    }

    /// Inverse of the `~` expansion in `canonicalLocal`, for *writing* a
    /// local path: the current home prefix contracts to `~` so saved project
    /// files stay valid when `~/.config/futuraterm` syncs (dotfiles) to a
    /// machine with a different user name. Paths outside home pass through.
    static func homeContracted(_ path: String) -> String {
        let home = currentHome
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Canonical form of a *local* path for identity comparisons (matching a
    /// project file's `path:` against a project's directory): tilde expanded
    /// (against `currentHome`), `.`/`..` segments standardized, trailing
    /// slash stripped. Symlinks are deliberately NOT resolved — two paths the
    /// user treats as distinct must stay distinct even when one links to the
    /// other.
    static func canonicalLocal(_ path: String) -> String {
        var expanded = path
        if expanded == "~" {
            expanded = currentHome
        } else if expanded.hasPrefix("~/") {
            expanded = currentHome + expanded.dropFirst(1)
        } else if expanded.hasPrefix("~") {
            // `~user/...` — no env override applies; defer to Foundation.
            expanded = (expanded as NSString).expandingTildeInPath
        }
        var standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        while standardized.count > 1, standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized
    }

    /// Grant-coverage form of a local path. Starts from `canonicalLocal`.
    /// Follows the longest existing prefix so a bookmark on a symlink folder
    /// covers a pane cwd whose last component does not exist yet (`link/src`),
    /// then re-appends the missing remainder. Then folds Darwin firmlink
    /// aliases (`/private/var`→`/var`, `/private/tmp`→`/tmp`, `/private/etc`
    /// →`/etc`) so a missing `/private/var/…` string still matches `/var/…`.
    /// Bookmark resolve yields `/private/var/folders` while
    /// `FileManager.temporaryDirectory` and stored pane cwds keep
    /// `/var/folders`; `standardizedFileURL` only folds those when the path
    /// exists, so coverage must fold them itself for missing paths too.
    /// Does not change `canonicalLocal` identity matching.
    static func resolvedLocal(_ path: String) -> String {
        let canonical = canonicalLocal(path)
        return foldDarwinPrivatePrefix(followLongestExistingPrefix(canonical))
    }

    /// `resolvingSymlinksInPath` leaves a missing last component unresolved,
    /// even when a parent symlink exists. Walk back to the longest prefix that
    /// exists, follow that, and re-append the remainder.
    private static func followLongestExistingPrefix(_ path: String) -> String {
        let fm = FileManager.default
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var remainder: [String] = []
        while true {
            let prefix = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
            if fm.fileExists(atPath: prefix) || parts.isEmpty {
                var resolved = prefix
                if fm.fileExists(atPath: prefix) {
                    resolved = URL(fileURLWithPath: prefix).resolvingSymlinksInPath().path
                    while resolved.count > 1, resolved.hasSuffix("/") {
                        resolved.removeLast()
                    }
                }
                guard !remainder.isEmpty else { return resolved }
                if resolved == "/" { return "/" + remainder.joined(separator: "/") }
                return resolved + "/" + remainder.joined(separator: "/")
            }
            remainder.insert(parts.removeLast(), at: 0)
        }
    }

    private static func foldDarwinPrivatePrefix(_ path: String) -> String {
        let aliases = [("/private/var", "/var"), ("/private/tmp", "/tmp"), ("/private/etc", "/etc")]
        for (priv, pub) in aliases {
            if path == priv { return pub }
            if path.hasPrefix(priv + "/") {
                return pub + path.dropFirst(priv.count)
            }
        }
        return path
    }

    /// Storage form of a raw project path: local paths canonicalized (tilde
    /// expanded, `.`/`..` standardized, trailing slash stripped); remote specs
    /// and unparseable strings pass through verbatim. A stored trailing slash
    /// would otherwise reach the spawned shell's `$PWD` verbatim (libghostty
    /// exports its `working_directory` string into the child env unmodified),
    /// and that is FATAL under nushell: nu refuses to start ("$env.PWD
    /// contains trailing slashes", nu-protocol `engine_state.rs`), so the
    /// pane dies in ~150ms on ghostty's abnormal-exit screen. zsh survives
    /// but renders `%c`/`%1~` of `/path/dir/` as the empty last component,
    /// blanking the prompt's directory segment until the first `cd`.
    static func normalizedForStorage(_ raw: String) -> String {
        if case let .local(path)? = parse(raw) { return canonicalLocal(path) }
        return raw
    }

    /// Convenience for call sites holding a raw path string (`Project.path`,
    /// `Pane.projectPath` — the remote spec travels and persists as a string).
    static func isRemote(_ raw: String) -> Bool {
        if case .remote = parse(raw) { return true }
        return false
    }

    /// The parsed spec when `raw` is a remote path; nil for local or invalid.
    /// The typed input for `RemoteSpawn` call sites.
    static func remote(from raw: String) -> ProjectPath? {
        guard let parsed = parse(raw), case .remote = parsed else { return nil }
        return parsed
    }

    /// Host of a remote spec, stripping `user@`. Nil for local or invalid.
    static func remoteHost(from raw: String) -> String? {
        guard case let .remote(_, host, _) = parse(raw) else { return nil }
        return host
    }

    /// Compose a remote `path:` string from the New Remote Project sheet's
    /// fields (`[user@]host` + directory), validating through the parser.
    /// nil when the pair doesn't form a well-formed remote spec.
    static func composeRemote(host: String, directory: String) -> String? {
        let composed = host.trimmingCharacters(in: .whitespaces)
            + ":"
            + directory.trimmingCharacters(in: .whitespaces)
        return isRemote(composed) ? composed : nil
    }

    /// Whether two raw path strings identify the same project location.
    /// Locals compare canonically; remotes compare structurally (same
    /// user/host/directory after parsing). A local never equals a remote,
    /// and unparseable strings match nothing.
    static func matches(_ a: String, _ b: String) -> Bool {
        switch (parse(a), parse(b)) {
        case let (.local(pa), .local(pb)):
            canonicalLocal(pa) == canonicalLocal(pb)
        case let (.remote(ua, ha, da), .remote(ub, hb, db)):
            ua == ub && ha == hb && da == db
        default:
            false
        }
    }
}
