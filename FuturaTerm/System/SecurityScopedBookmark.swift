import AppKit
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "SecurityScopedBookmark")

/// Creates and resolves security-scoped bookmarks for MAS sandbox access to
/// user-chosen folders (and optional custom Ghostty config files).
///
/// Direct/Debug stores bookmarks without `.withSecurityScope` so unsandboxed
/// launches keep working. App Store uses the security-scope option.
enum SecurityScopedBookmark {
    enum StartResult: Equatable {
        case success(URL)
        case stale
        case failed
        case unused
    }

    static var usesSecurityScope: Bool { AppDistribution.isAppStore }

    /// Stale/failed always need a re-grant. Missing bookmarks (`.unused`) do
    /// too on MAS — CLI create, Direct→MAS import, and setPath otherwise
    /// never prompt. Direct/Debug skip: there is no sandbox to grant.
    static func needsUserGrant(
        _ result: StartResult,
        usesSecurityScope: Bool = usesSecurityScope
    ) -> Bool {
        switch result {
        case .stale,
             .failed: true
        case .unused: usesSecurityScope
        case .success: false
        }
    }

    /// Local MAS panes must not spawn until the project-folder grant is held.
    /// Remote panes have no local folder; Direct/Debug has no sandbox.
    static func canSpawnLocalPane(
        isRemote: Bool,
        isHoldingGrant: Bool,
        usesSecurityScope: Bool = usesSecurityScope
    ) -> Bool {
        if isRemote || !usesSecurityScope { return true }
        return isHoldingGrant
    }

    /// Whether `folder` is `path` or an ancestor of it. Used to accept an
    /// Open-panel re-grant and to keep a parent bookmark across setPath.
    /// Both sides go through `ProjectPath.resolvedLocal` so a held bookmark
    /// URL (`/private/var/folders/...`, or a symlink folder) covers a pane
    /// cwd stored as `/var` or the real vnode.
    /// Same-vnode link↔real stays covered. Resolved ancestry is used only when
    /// the resolved grant root is not a proper ancestor of the canonical grant
    /// path — an upward symlink (`…/app/up` → `…/app`) must not cover siblings
    /// (`…/app/other`).
    static func folder(_ folder: String, covers path: String) -> Bool {
        let root = ProjectPath.resolvedLocal(folder)
        let child = ProjectPath.resolvedLocal(path)
        if child == root { return true }

        let canonicalRoot = ProjectPath.canonicalLocal(folder)
        if isProperAncestor(root, of: canonicalRoot) {
            return false
        }

        if root == "/" { return child.hasPrefix("/") }
        return child.hasPrefix(root + "/")
    }

    private static func isProperAncestor(_ ancestor: String, of path: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") && path != "/" }
        return path.hasPrefix(ancestor + "/")
    }

    /// Child file URL under a still-started parent, so MAS can mint a
    /// descendant bookmark without dropping the parent grant first.
    /// Prefix matching uses `resolvedLocal` so a held symlink folder and a
    /// target on the real vnode (or `/var` vs `/private/var`) stay one grant
    /// root; the remainder is appended onto `held`.
    static func childURL(held: URL, grantedPath: String, targetPath: String) -> URL {
        let granted = ProjectPath.resolvedLocal(grantedPath)
        let target = ProjectPath.resolvedLocal(targetPath)
        if target == granted { return held }
        let prefix = granted == "/" ? "/" : granted + "/"
        guard target.hasPrefix(prefix) else { return URL(fileURLWithPath: target) }
        let rest = String(target.dropFirst(prefix.count))
        return rest.split(separator: "/").reduce(held) {
            $0.appendingPathComponent(String($1), isDirectory: true)
        }
    }

    static func create(from url: URL) -> Data? {
        let options: URL.BookmarkCreationOptions = usesSecurityScope ? [.withSecurityScope] : []
        do {
            return try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            logger.error(
                "bookmark create failed: \(error.localizedDescription, privacy: .public) path=\(url.path, privacy: .public)"
            )
            return nil
        }
    }

    static func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        // `.withSecurityScope` otherwise starts access as a side effect of
        // resolve (macOS 11.2+). `.withoutImplicitStartAccessing` keeps the
        // only start on the explicit `startAccessing` call so one `stop` pairs.
        let options: URL.BookmarkResolutionOptions = usesSecurityScope
            ? [.withSecurityScope, .withoutImplicitStartAccessing]
            : []
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        else { return nil }
        return (url, isStale)
    }

    /// Resolve then one `startAccessingSecurityScopedResource()`. Direct
    /// builds skip startAccessing (no-op success using the file URL).
    /// Apple's contract is stop only after a successful start: an extra stop
    /// on stale resolve or failed `startAccessing` decrements the per-URL
    /// kernel count and can drop a sibling project's live grant for the
    /// same folder. `.withoutImplicitStartAccessing` keeps resolve from
    /// pairing a start we would need to undo.
    static func start(_ data: Data) -> StartResult {
        guard let resolved = resolve(data) else { return .failed }
        if resolved.isStale {
            return .stale
        }
        if usesSecurityScope {
            guard resolved.url.startAccessingSecurityScopedResource() else {
                return .failed
            }
        }
        return .success(resolved.url)
    }

    static func stop(_ url: URL) {
        guard usesSecurityScope else { return }
        url.stopAccessingSecurityScopedResource()
    }
}

/// Per-project start/stop pairing for security-scoped folder access.
/// `begin` is idempotent: re-select does not extra-start; one `end` stops.
@MainActor
final class SecurityScopedAccess {
    private var urls: [UUID: URL] = [:]

    func isHolding(_ projectID: UUID) -> Bool {
        urls[projectID] != nil
    }

    /// The live security-scoped URL, if this grant is held. Used to remint a
    /// child bookmark while the parent folder is still started.
    func heldURL(for projectID: UUID) -> URL? {
        urls[projectID]
    }

    @discardableResult
    func begin(projectID: UUID, bookmark: Data?) -> SecurityScopedBookmark.StartResult {
        guard let bookmark else {
            end(projectID: projectID)
            return .unused
        }
        if let existing = urls[projectID] {
            guard let resolved = SecurityScopedBookmark.resolve(bookmark) else {
                return .success(existing)
            }
            let samePath = ProjectPath.canonicalLocal(existing.path)
                == ProjectPath.canonicalLocal(resolved.url.path)
            if samePath, !resolved.isStale {
                return .success(existing)
            }
            end(projectID: projectID)
            if resolved.isStale {
                return .stale
            }
        }
        let result = SecurityScopedBookmark.start(bookmark)
        if case let .success(url) = result {
            urls[projectID] = url
        }
        return result
    }

    func end(projectID: UUID) {
        if let url = urls.removeValue(forKey: projectID) {
            SecurityScopedBookmark.stop(url)
        }
    }
}

/// Bookmarks for custom Ghostty config files picked in Settings (not projects.json).
enum GhosttyConfigFileBookmarks {
    private static let defaultsKey = "futuraterm.ghostty.configFileBookmarks"

    static func remember(path: String, data: Data) {
        var map = loadMap()
        map[path] = data.base64EncodedString()
        Preferences.defaults.set(map, forKey: defaultsKey)
    }

    private static let live = LiveURLs()

    static func startAccessing(
        path: String,
        usesSecurityScope: Bool = SecurityScopedBookmark.usesSecurityScope
    ) -> SecurityScopedBookmark.StartResult {
        let expanded = (path as NSString).expandingTildeInPath
        if let url = live.url(for: expanded) ?? live.url(for: path) {
            return .success(url)
        }
        let map = loadMap()
        guard let b64 = map[path] ?? map[expanded],
              let data = Data(base64Encoded: b64)
        else {
            if SecurityScopedBookmark.needsUserGrant(.unused, usesSecurityScope: usesSecurityScope) {
                notePendingRepick(expanded)
            }
            return .unused
        }
        let result = SecurityScopedBookmark.start(data)
        switch result {
        case let .success(url):
            live.set(url, for: expanded)
            live.clearFailed(path)
            live.clearFailed(expanded)
        case .stale,
             .failed:
            live.markFailed(path)
            live.markFailed(expanded)
            notePendingRepick(expanded)
        case .unused:
            if SecurityScopedBookmark.needsUserGrant(.unused, usesSecurityScope: usesSecurityScope) {
                notePendingRepick(expanded)
            }
        }
        return result
    }

    static func needsRepick(_ path: String) -> Bool {
        live.needsRepick(path)
    }

    static func notePendingRepick(_ path: String) {
        live.notePendingRepick(path)
    }

    static func nextPendingRepick() -> String? {
        live.nextPendingRepick()
    }

    /// Open-panel re-pick for a remembered custom config whose bookmark died.
    /// Requires the chosen file to be the listed path (not a sibling).
    @MainActor
    @discardableResult
    static func presentRepick(for path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        panel.message = "FuturaTerm needs access to this Ghostty config file again."
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let picked = url.standardizedFileURL.path
        guard picked == URL(fileURLWithPath: expanded).standardizedFileURL.path else {
            return false
        }
        guard let data = SecurityScopedBookmark.create(from: url) else {
            return false
        }
        remember(path: path, data: data)
        remember(path: expanded, data: data)
        live.clearFailed(path)
        live.clearFailed(expanded)
        switch startAccessing(path: expanded) {
        case .success: return true
        default: return false
        }
    }

    static func stopAccessing(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        var stopped: Set<URL> = []
        for key in Set([path, expanded]) {
            guard let url = live.remove(key), stopped.insert(url).inserted else { continue }
            SecurityScopedBookmark.stop(url)
        }
    }

    private final class LiveURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String: URL] = [:]
        private var failedPaths: Set<String> = []
        private var pendingRepick: [String] = []

        func url(for path: String) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return urls[path]
        }

        func set(_ url: URL, for path: String) {
            lock.lock()
            urls[path] = url
            lock.unlock()
        }

        func remove(_ path: String) -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return urls.removeValue(forKey: path)
        }

        func needsRepick(_ path: String) -> Bool {
            let expanded = (path as NSString).expandingTildeInPath
            lock.lock()
            defer { lock.unlock() }
            return failedPaths.contains(path) || failedPaths.contains(expanded)
        }

        func markFailed(_ path: String) {
            lock.lock()
            failedPaths.insert(path)
            lock.unlock()
        }

        func clearFailed(_ path: String) {
            lock.lock()
            failedPaths.remove(path)
            lock.unlock()
        }

        func notePendingRepick(_ path: String) {
            let expanded = (path as NSString).expandingTildeInPath
            lock.lock()
            failedPaths.insert(expanded)
            if !pendingRepick.contains(expanded) {
                pendingRepick.append(expanded)
            }
            lock.unlock()
        }

        func nextPendingRepick() -> String? {
            lock.lock()
            defer { lock.unlock() }
            guard !pendingRepick.isEmpty else { return nil }
            return pendingRepick.removeFirst()
        }
    }

    private static func loadMap() -> [String: String] {
        Preferences.defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }
}
