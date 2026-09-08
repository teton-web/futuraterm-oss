import Foundation
@testable import FuturaTerm
import Testing

struct SecurityScopedBookmarkTests {
    @Test
    func round_trip_temp_directory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-ssb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = try #require(SecurityScopedBookmark.create(from: dir))
        #expect(!data.isEmpty)

        let resolved = try #require(SecurityScopedBookmark.resolve(data))
        #expect(resolved.isStale == false)
        #expect(resolved.url.standardizedFileURL.path == dir.standardizedFileURL.path)

        let started = SecurityScopedBookmark.start(data)
        if case let .success(url) = started {
            SecurityScopedBookmark.stop(url)
            #expect(url.standardizedFileURL.path == dir.standardizedFileURL.path)
        } else {
            Issue.record("expected success, got \(started)")
        }
    }

    @Test
    func debug_host_does_not_require_security_scope() {
        #expect(AppDistribution.isAppStore == false)
        #expect(SecurityScopedBookmark.usesSecurityScope == false)
    }

    @Test
    func needsUserGrant_unused_only_on_app_store() {
        #expect(SecurityScopedBookmark.needsUserGrant(.unused, usesSecurityScope: false) == false)
        #expect(SecurityScopedBookmark.needsUserGrant(.unused, usesSecurityScope: true) == true)
        #expect(SecurityScopedBookmark.needsUserGrant(.stale, usesSecurityScope: false) == true)
        #expect(SecurityScopedBookmark.needsUserGrant(.failed, usesSecurityScope: true) == true)
        let url = URL(fileURLWithPath: "/tmp")
        #expect(SecurityScopedBookmark.needsUserGrant(.success(url), usesSecurityScope: true) == false)
    }

    @Test
    func canSpawnLocalPane_waits_for_mas_folder_grant() {
        #expect(!SecurityScopedBookmark.canSpawnLocalPane(
            isRemote: false,
            isHoldingGrant: false,
            usesSecurityScope: true
        ))
        #expect(SecurityScopedBookmark.canSpawnLocalPane(
            isRemote: false,
            isHoldingGrant: true,
            usesSecurityScope: true
        ))
        #expect(SecurityScopedBookmark.canSpawnLocalPane(
            isRemote: false,
            isHoldingGrant: false,
            usesSecurityScope: false
        ))
        #expect(SecurityScopedBookmark.canSpawnLocalPane(
            isRemote: true,
            isHoldingGrant: false,
            usesSecurityScope: true
        ))
    }

    @Test
    func folder_covers_project_or_ancestor_not_sibling() {
        #expect(SecurityScopedBookmark.folder("/Users/me/proj", covers: "/Users/me/proj"))
        #expect(SecurityScopedBookmark.folder("/Users/me/proj", covers: "/Users/me/proj/src"))
        #expect(SecurityScopedBookmark.folder("/Users/me", covers: "/Users/me/proj"))
        #expect(!SecurityScopedBookmark.folder("/Users/me/proj", covers: "/Users/me/other"))
        #expect(!SecurityScopedBookmark.folder("/Users/me/proj/src", covers: "/Users/me/proj"))
    }

    @Test
    func folder_covers_var_and_private_var_aliases() {
        #expect(SecurityScopedBookmark.folder(
            "/private/var/folders/zz/futuraterm-f44",
            covers: "/var/folders/zz/futuraterm-f44"
        ))
        #expect(SecurityScopedBookmark.folder(
            "/var/folders/zz/futuraterm-f44",
            covers: "/private/var/folders/zz/futuraterm-f44/pane"
        ))
        #expect(SecurityScopedBookmark.folder("/private/tmp/f44", covers: "/tmp/f44"))
        #expect(!SecurityScopedBookmark.folder(
            "/private/var/folders/zz/futuraterm-f44",
            covers: "/var/folders/zz/other"
        ))
    }

    @Test
    func folder_covers_temp_directory_grant_and_unresolved_var_cwd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-ssb-var-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = try #require(SecurityScopedBookmark.create(from: dir))
        let resolved = try #require(SecurityScopedBookmark.resolve(data))
        #expect(SecurityScopedBookmark.folder(resolved.url.path, covers: dir.path))
        #expect(SecurityScopedBookmark.folder(dir.path, covers: resolved.url.path))
    }

    @Test
    func folder_covers_symlink_folder_and_real_vnode() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("futuraterm-ssb-link-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        #expect(SecurityScopedBookmark.folder(link.path, covers: real.path))
        #expect(SecurityScopedBookmark.folder(real.path, covers: link.path))
        let nested = real.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(SecurityScopedBookmark.folder(link.path, covers: nested.path))
        #expect(SecurityScopedBookmark.folder(
            real.path,
            covers: link.appendingPathComponent("src", isDirectory: true).path
        ))

        let data = try #require(SecurityScopedBookmark.create(from: link))
        let resolved = try #require(SecurityScopedBookmark.resolve(data))
        #expect(SecurityScopedBookmark.folder(resolved.url.path, covers: real.path))
        #expect(SecurityScopedBookmark.folder(real.path, covers: resolved.url.path))

        // Layout `cwd: src` often does not exist yet; the symlink prefix must
        // still cover it the same way the real vnode does.
        let missing = link.appendingPathComponent("src", isDirectory: true).path
        #expect(SecurityScopedBookmark.folder(link.path, covers: missing))
        #expect(SecurityScopedBookmark.folder(real.path, covers: missing))
    }

    @Test
    func folder_upward_symlink_does_not_cover_siblings() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("futuraterm-ssb-up-\(UUID().uuidString)", isDirectory: true)
        let app = base.appendingPathComponent("app", isDirectory: true)
        let other = app.appendingPathComponent("other", isDirectory: true)
        let up = app.appendingPathComponent("up", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: up.path, withDestinationPath: "..")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        #expect(!SecurityScopedBookmark.folder(up.path, covers: other.path))
        #expect(SecurityScopedBookmark.folder(link.path, covers: real.path))
        #expect(SecurityScopedBookmark.folder(real.path, covers: link.path))
    }

    @Test
    func child_url_appends_under_held_parent() {
        let held = URL(fileURLWithPath: "/Users/me/proj", isDirectory: true)
        let child = SecurityScopedBookmark.childURL(
            held: held,
            grantedPath: "/Users/me/proj",
            targetPath: "/Users/me/proj/src"
        )
        #expect(child.path == held.appendingPathComponent("src", isDirectory: true).path)
        let same = SecurityScopedBookmark.childURL(
            held: held,
            grantedPath: "/Users/me/proj",
            targetPath: "/Users/me/proj"
        )
        #expect(same.path == held.path)
        // A parent Open-panel pick holds `/Users/me` while project.path is
        // `/Users/me/proj`. The suffix must be taken from the held root, or
        // replace-path to `/Users/me/proj/src` mints sibling `/Users/me/src`.
        let parent = URL(fileURLWithPath: "/Users/me", isDirectory: true)
        let descendant = SecurityScopedBookmark.childURL(
            held: parent,
            grantedPath: parent.path,
            targetPath: "/Users/me/proj/src"
        )
        #expect(descendant.path == "/Users/me/proj/src")
        let siblingTrap = SecurityScopedBookmark.childURL(
            held: parent,
            grantedPath: "/Users/me/proj",
            targetPath: "/Users/me/proj/src"
        )
        #expect(siblingTrap.path == "/Users/me/src")
    }

    @Test
    func child_url_treats_symlink_folder_and_real_vnode_as_one_root() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("futuraterm-ssb-child-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        let src = real.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: base) }

        let fromLink = SecurityScopedBookmark.childURL(
            held: link,
            grantedPath: link.path,
            targetPath: src.path
        )
        #expect(fromLink.path == link.appendingPathComponent("src", isDirectory: true).path)

        let fromReal = SecurityScopedBookmark.childURL(
            held: real,
            grantedPath: real.path,
            targetPath: link.appendingPathComponent("src", isDirectory: true).path
        )
        #expect(fromReal.path == src.path)

        let sameViaReal = SecurityScopedBookmark.childURL(
            held: link,
            grantedPath: link.path,
            targetPath: real.path
        )
        #expect(sameViaReal.path == link.path)
    }

    @Test
    func config_bookmark_repick_tracks_failed_paths() {
        let path = "/tmp/ghostty-config-repick-\(UUID().uuidString)"
        #expect(!GhosttyConfigFileBookmarks.needsRepick(path))
        GhosttyConfigFileBookmarks.notePendingRepick(path)
        #expect(GhosttyConfigFileBookmarks.needsRepick(path))
        #expect(GhosttyConfigFileBookmarks.nextPendingRepick() == path)
        #expect(GhosttyConfigFileBookmarks.nextPendingRepick() == nil)
    }

    @Test
    func unused_config_path_queues_repick_under_security_scope() {
        let path = "/tmp/ghostty-config-unused-\(UUID().uuidString)"
        let result = GhosttyConfigFileBookmarks.startAccessing(path: path, usesSecurityScope: true)
        #expect(result == .unused)
        #expect(GhosttyConfigFileBookmarks.needsRepick(path))
    }

    @Test
    func unused_config_path_does_not_queue_repick_on_direct() {
        let path = "/tmp/ghostty-config-unused-direct-\(UUID().uuidString)"
        let result = GhosttyConfigFileBookmarks.startAccessing(path: path, usesSecurityScope: false)
        #expect(result == .unused)
        #expect(!GhosttyConfigFileBookmarks.needsRepick(path))
    }

    @Test
    func garbage_data_fails_closed() {
        let result = SecurityScopedBookmark.start(Data([0x00, 0x01, 0x02]))
        #expect(result == .failed)
        #expect(SecurityScopedBookmark.resolve(Data([0xFF])) == nil)
    }

    @Test
    func resolve_opts_out_of_implicit_start() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("FuturaTerm/System/SecurityScopedBookmark.swift"),
            encoding: .utf8
        )
        #expect(source.contains(".withoutImplicitStartAccessing"))
        let startMark = try #require(source.range(of: "static func start(_ data: Data)"))
        let startRest = source[startMark.lowerBound...]
        let startEnd = startRest.range(of: "\n    static func ")
        let startFn = if let startEnd {
            String(startRest[..<startEnd.lowerBound])
        } else {
            String(startRest.prefix(800))
        }
        #expect(startFn.contains("if resolved.isStale"))
        #expect(!startFn.contains("stop("))
        #expect(!startFn.contains("stopAccessing"))
        let beginMark = try #require(source.range(of: "func begin(projectID: UUID, bookmark: Data?)"))
        let beginRest = source[beginMark.lowerBound...]
        let beginEnd = beginRest.range(of: "\n    func end(")
        let beginFn = if let beginEnd {
            String(beginRest[..<beginEnd.lowerBound])
        } else {
            String(beginRest.prefix(1200))
        }
        #expect(beginFn.contains("resolved.isStale"))
        #expect(!beginFn.contains("SecurityScopedBookmark.stop(resolved.url)"))
    }

    @Test
    func config_repick_call_sites_reload_libghostty() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ghostty = try String(
            contentsOf: root.appendingPathComponent("FuturaTerm/Ghostty/GhosttyApp.swift"),
            encoding: .utf8
        )
        #expect(ghostty.contains("repickConfigFilesAndReload(result.inaccessibleConfigBookmarkPaths)"))
        #expect(ghostty.contains("func repickConfigFilesAndReload"))
        #expect(ghostty.contains("return reloadAndReport()"))
        #expect(ghostty.contains("if SecurityScopedBookmark.needsUserGrant(access)"))
        let terminal = try String(
            contentsOf: root.appendingPathComponent("FuturaTerm/Views/TerminalPane.swift"),
            encoding: .utf8
        )
        #expect(terminal.contains("canSpawn: canSpawnSurface"))
        #expect(terminal.contains("guard canSpawn else"))
        let makeMark = try #require(terminal.range(of: "func makeNSView"))
        let makeRest = terminal[makeMark.lowerBound...]
        let makeEnd = makeRest.range(of: "\n    func updateNSView")
        let makeFn = if let makeEnd {
            String(makeRest[..<makeEnd.lowerBound])
        } else {
            String(makeRest.prefix(1600))
        }
        let spawnGuard = try #require(makeFn.range(of: "guard canSpawn else"))
        let spawnRest = makeFn[spawnGuard.lowerBound...]
        let spawnEnd = spawnRest.range(of: "let scroll")
        let blocked = if let spawnEnd {
            String(spawnRest[..<spawnEnd.lowerBound])
        } else {
            String(spawnRest.prefix(400))
        }
        #expect(!blocked.contains("wasFocused ="))
        let main = try String(
            contentsOf: root.appendingPathComponent("FuturaTerm/Views/MainWindow.swift"),
            encoding: .utf8
        )
        #expect(main.contains("repickConfigFilesAndReload"))
        let settings = try String(
            contentsOf: root.appendingPathComponent("FuturaTerm/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(settings.contains("GhosttyConfigFileBookmarks.presentRepick"))
        #expect(settings.contains("commitGhosttyConfig()"))
        let appState = try String(
            contentsOf: root.appendingPathComponent("FuturaTerm/App/AppState.swift"),
            encoding: .utf8
        )
        #expect(appState.contains("completeSecurityScopeRegrant(store: store, projectID: projectID, pickedURL: picked)"))
        #expect(appState.contains("applySuccessfulFolderGrant(projectID: projectID)"))
        #expect(appState.contains("killSessionsBlocking(names)"))
        #expect(appState.contains("resetSurfaceForFirstSpawn()"))
        let grantStart = try #require(appState.range(of: "func applySuccessfulFolderGrant"))
        let grantRest = appState[grantStart.lowerBound...]
        let grantEnd = grantRest.range(of: "\n    func ")
            ?? grantRest.range(of: "\n    private func ")
        let grantFn = if let grantEnd {
            String(grantRest[..<grantEnd.lowerBound])
        } else {
            String(grantRest.prefix(800))
        }
        #expect(grantFn.contains("killSessionsBlocking"))
        #expect(!grantFn.contains("reconnectSurface"))
    }

    @Test
    func config_bookmark_stop_uses_the_expanded_start_key() throws {
        let home = NSHomeDirectory()
        let dir = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("futuraterm-cfg-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.ghostty")
        try Data("theme = test\n".utf8).write(to: file)
        let expanded = file.standardizedFileURL.path
        #expect(expanded.hasPrefix(home + "/"))
        let tilde = "~" + expanded.dropFirst(home.count)
        #expect((tilde as NSString).expandingTildeInPath == expanded)

        let data = try #require(SecurityScopedBookmark.create(from: file))
        GhosttyConfigFileBookmarks.remember(path: expanded, data: data)
        let started = GhosttyConfigFileBookmarks.startAccessing(
            path: expanded,
            usesSecurityScope: false
        )
        guard case .success = started else {
            Issue.record("startAccessing failed")
            return
        }
        GhosttyConfigFileBookmarks.stopAccessing(path: tilde)
        GhosttyConfigFileBookmarks.remember(path: expanded, data: Data([0xFF]))
        let again = GhosttyConfigFileBookmarks.startAccessing(
            path: expanded,
            usesSecurityScope: false
        )
        if case .success = again {
            Issue.record("stopAccessing missed the expanded live key")
        }
        #expect(again == .failed || again == .stale)
    }

    @Test
    func start_then_one_stop_pairs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-ssb-pair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try #require(SecurityScopedBookmark.create(from: dir))
        guard case let .success(url) = SecurityScopedBookmark.start(data) else {
            Issue.record("start failed")
            return
        }
        SecurityScopedBookmark.stop(url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
struct SecurityScopedAccessTests {
    @Test
    func begin_is_idempotent_one_end_releases() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-ssa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try #require(SecurityScopedBookmark.create(from: dir))
        let access = SecurityScopedAccess()
        let id = UUID()

        #expect(access.begin(projectID: id, bookmark: data) != .failed)
        #expect(access.isHolding(id))
        _ = access.begin(projectID: id, bookmark: data)
        _ = access.begin(projectID: id, bookmark: data)
        access.end(projectID: id)
        #expect(!access.isHolding(id))
        access.end(projectID: id)
        #expect(!access.isHolding(id))
    }

    @Test
    func begin_replaces_held_url_when_bookmark_points_elsewhere() throws {
        let a = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-ssa-a-\(UUID().uuidString)", isDirectory: true)
        let b = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-ssa-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let dataA = try #require(SecurityScopedBookmark.create(from: a))
        let dataB = try #require(SecurityScopedBookmark.create(from: b))
        let access = SecurityScopedAccess()
        let id = UUID()

        guard case let .success(first) = access.begin(projectID: id, bookmark: dataA) else {
            Issue.record("first begin failed")
            return
        }
        #expect(ProjectPath.canonicalLocal(first.path) == ProjectPath.canonicalLocal(a.path))
        guard case let .success(second) = access.begin(projectID: id, bookmark: dataB) else {
            Issue.record("replacement begin failed")
            return
        }
        #expect(ProjectPath.canonicalLocal(second.path) == ProjectPath.canonicalLocal(b.path))
        #expect(access.isHolding(id))
        access.end(projectID: id)
        #expect(!access.isHolding(id))
    }

    @Test
    func begin_unused_releases_a_held_url() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-ssa-unused-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try #require(SecurityScopedBookmark.create(from: dir))
        let access = SecurityScopedAccess()
        let id = UUID()
        _ = access.begin(projectID: id, bookmark: data)
        #expect(access.isHolding(id))
        #expect(access.begin(projectID: id, bookmark: nil) == .unused)
        #expect(!access.isHolding(id))
    }

    @Test
    func heldURL_returns_started_url() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-ssa-held-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try #require(SecurityScopedBookmark.create(from: dir))
        let access = SecurityScopedAccess()
        let id = UUID()
        _ = access.begin(projectID: id, bookmark: data)
        let held = try #require(access.heldURL(for: id))
        #expect(ProjectPath.canonicalLocal(held.path) == ProjectPath.canonicalLocal(dir.path))
        access.end(projectID: id)
        #expect(access.heldURL(for: id) == nil)
    }

    @Test
    func two_projects_on_one_folder_keep_independent_holds() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-ssa-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try #require(SecurityScopedBookmark.create(from: dir))
        let access = SecurityScopedAccess()
        let a = UUID()
        let b = UUID()
        #expect(access.begin(projectID: a, bookmark: data) != .failed)
        #expect(access.begin(projectID: b, bookmark: data) != .failed)
        #expect(access.isHolding(a))
        #expect(access.isHolding(b))
        access.end(projectID: a)
        #expect(!access.isHolding(a))
        #expect(access.isHolding(b))
        access.end(projectID: b)
        #expect(!access.isHolding(b))
    }
}
