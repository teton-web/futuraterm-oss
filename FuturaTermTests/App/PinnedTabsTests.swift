import Foundation
@testable import FuturaTerm
import os
import Testing

/// Pinned tabs: the sentinel workspace, pin/unpin moves, the
/// can't-close rule, unload-on-session-death + restore-from-declaration, and
/// the `pinned.yaml` write/absorb contract.
@MainActor
struct PinnedTabsTests {
    // MARK: - Setup helpers

    private struct Fixture {
        let state: AppState
        let storeURL: URL
        let projectsDir: URL
    }

    /// AppState with temp-file stores and a no-op zmx (a test must never fork
    /// the real zmx or reap the developer's live sessions).
    private func makeFixture() -> Fixture {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-\(UUID().uuidString).json")
        let projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
        state.zmx = .noop
        // Never let the eager pinned launch warm REAL surfaces in the test
        // host (that would spawn actual shells).
        state.warmPane = { _ in }
        return Fixture(state: state, storeURL: storeURL, projectsDir: projectsDir)
    }

    private func seedProject(_ state: AppState, name: String = "proj", path: String = "/tmp") -> Project {
        let p = Project(name: name, path: path, sortOrder: 0)
        state.selectProject(p)
        return p
    }

    private var pinnedID: UUID { PinnedTabs.projectID }

    // MARK: - Pin

    @Test
    func pinTab_moves_tab_into_pinned_workspace_and_records_it() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)

        fx.state.pinTab(tab.id, fromProject: p.id)

        #expect(fx.state.workspaces[p.id]?.tabs.isEmpty == true)
        #expect(fx.state.pinnedWorkspace?.tabs.map(\.id) == [tab.id])
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
        #expect(fx.state.pinnedRecords.first?.originProjectID == p.id)
        #expect(fx.state.pinnedRecords.first?.originFolderPath == p.path)
        #expect(pane.projectID == pinnedID)
        #expect(fx.state.activeProjectID == pinnedID)
    }

    @Test
    func workspace_snapshot_preserves_origin_folder_grant() {
        let fx = makeFixture()
        let origin = UUID()
        let blob = Data("origin-bookmark".utf8)
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "dev", layout: .pane(LayoutPane(cwd: "/tmp/proj"))),
            originProjectID: origin,
            originFolderPath: "/tmp/proj",
            originFolderBookmark: blob
        )]
        fx.state.saveWorkspaces()
        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        #expect(loaded.pinned.first?.originProjectID == origin)
        #expect(loaded.pinned.first?.originFolderPath == "/tmp/proj")
        #expect(loaded.pinned.first?.originFolderBookmark == blob)
    }

    @Test
    func workspace_snapshot_preserves_covering_grants() {
        let fx = makeFixture()
        let origin = UUID()
        let extra = UUID()
        let originBlob = Data("origin-bookmark".utf8)
        let extraBlob = Data("extra-bookmark".utf8)
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "dev", layout: .pane(LayoutPane(cwd: "/tmp/proj"))),
            originProjectID: origin,
            originFolderPath: "/tmp/proj",
            originFolderBookmark: originBlob,
            coveringGrants: [
                PinnedCoveringGrant(id: extra, folderPath: "/tmp/other", folderBookmark: extraBlob),
            ]
        )]
        fx.state.saveWorkspaces()
        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        #expect(loaded.pinned.first?.coveringGrants?.count == 1)
        #expect(loaded.pinned.first?.coveringGrants?.first?.id == extra)
        #expect(loaded.pinned.first?.coveringGrants?.first?.folderPath == "/tmp/other")
        #expect(loaded.pinned.first?.coveringGrants?.first?.folderBookmark == extraBlob)
    }

    @Test
    func pinTab_writes_pinned_yaml_with_marker_and_id() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)

        fx.state.pinTab(tab.id, fromProject: p.id)

        let text = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(text.contains("<pinned>"))
        // No wire-level ids — entries stay hand-editable.
        #expect(!text.contains(tab.id.uuidString))
    }

    @Test
    func moveTab_into_pinned_routes_to_pin() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)

        fx.state.moveTab(tab.id, from: p.id, to: pinnedID, destPath: "/anything")

        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
        #expect(fx.state.pinnedWorkspace?.tabs.map(\.id) == [tab.id])
    }

    @Test
    func new_tab_created_inside_pinned_workspace_gets_a_record() throws {
        let fx = makeFixture()
        fx.state.selectPinnedProject()
        let tabID = try #require(
            fx.state.createTab(projectID: pinnedID, projectPath: PinnedTabs.fallbackRoot)
        )
        #expect(fx.state.pinnedRecords.map(\.id) == [tabID])
    }

    // MARK: - Unpin

    @Test
    func unpinTab_returns_loaded_tab_to_origin_project() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        fx.state.unpinTab(tab.id, projects: [p])

        #expect(fx.state.pinnedRecords.isEmpty)
        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.workspaces[p.id]?.tabs.map(\.id) == [tab.id])
        #expect(tab.splitRoot.allPanes().first?.projectID == p.id)
    }

    @Test
    func unpinTab_unloaded_record_is_forgotten() {
        let fx = makeFixture()
        let record = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(layout: .pane(LayoutPane(cwd: "/tmp"))),
            originProjectID: nil
        )
        fx.state.pinnedRecords = [record]

        fx.state.unpinTab(record.id, projects: [])

        #expect(fx.state.pinnedRecords.isEmpty)
    }

    // MARK: - Close = unload

    /// One `AppCommand.closeTab` serves both kinds of tab: on the pinned
    /// workspace it unloads (record kept), on a project it closes for good.
    @Test
    func closeTab_command_unloads_pinned_and_closes_normal_tabs() throws {
        let fx = makeFixture()
        let storeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-projstore-\(UUID().uuidString).json")
        let ctx = AppCommandContext(appState: fx.state, projectStore: ProjectStore(fileURL: storeTmp))
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        // Active tab is the pinned one → close unloads, keeping the record.
        // (Bound before calling: invoking the `#require` result directly
        // crashes the Swift 6.3 frontend.)
        let closePinned = try #require(AppCommand.closeTab.action(in: ctx))
        closePinned()
        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])

        // Back on the project (pinning moved its only tab out, so make a
        // fresh one), close removes the tab outright.
        fx.state.activeProjectID = p.id
        _ = try #require(fx.state.createTab(projectID: p.id, projectPath: p.path))
        let closeNormal = try #require(AppCommand.closeTab.action(in: ctx))
        closeNormal()
        #expect(fx.state.workspaces[p.id]?.tabs.isEmpty == true)
    }

    @Test
    func requestCloseTab_unloads_pinned_tab_keeping_the_record() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        fx.state.requestCloseTab(tab.id, projectID: pinnedID)

        // Sessions end and the live tab goes — but the record (the dimmed
        // row, and its pinned.yaml entry) stays; unpin is the removal path.
        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
    }

    @Test
    func closeTabs_bulk_unloads_pinned_and_closes_normal_tabs() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let pinnedTab = ws.tabs[0]
        let normalTab = ws.createTab(projectPath: p.path)
        fx.state.pinTab(pinnedTab.id, fromProject: p.id)

        fx.state.closeTabs([
            (tabID: pinnedTab.id, projectID: pinnedID),
            (tabID: normalTab.id, projectID: p.id),
        ])

        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [pinnedTab.id])
        #expect(fx.state.workspaces[p.id]?.tabs.isEmpty == true)
    }

    @Test
    func closePane_last_pane_of_pinned_tab_unloads_it() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        fx.state.closePane(paneID, projectID: pinnedID)

        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
    }

    @Test
    func closePane_allows_inner_pane_of_pinned_split() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let newPane = try #require(tab.split(paneID: tab.splitRoot.allPanes()[0].id, direction: .horizontal))

        fx.state.closePane(newPane, projectID: pinnedID)

        #expect(tab.splitRoot.allPanes().count == 1)
        #expect(fx.state.pinnedWorkspace?.tabs.count == 1)
    }

    // MARK: - Session death → unload → restore

    @Test
    func paneProcessExited_last_pane_unloads_tab_keeping_record() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        fx.state.paneProcessExited(paneID, projectID: pinnedID)

        #expect(fx.state.pinnedWorkspace?.tabs.isEmpty == true)
        #expect(fx.state.pinnedRecords.map(\.id) == [tab.id])
        #expect(fx.state.isPinnedTabLoaded(tab.id) == false)
    }

    @Test
    func selectPinnedTab_rebuilds_unloaded_tab_from_declaration() throws {
        let fx = makeFixture()
        let recordID = UUID()
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: recordID,
            declaration: LayoutTab(
                name: "dev",
                layout: .pane(LayoutPane(cwd: "/tmp", run: "npm run dev"))
            ),
            originProjectID: nil
        )]

        fx.state.selectPinnedTab(recordID)

        let tab = try #require(fx.state.pinnedWorkspace?.tabs.first)
        #expect(tab.id == recordID)
        #expect(tab.customTitle == "dev")
        let pane = try #require(tab.splitRoot.allPanes().first)
        #expect(pane.command == "npm run dev")
        #expect(pane.projectPath == "/tmp")
        #expect(fx.state.activeProjectID == pinnedID)
        #expect(fx.state.pinnedWorkspace?.activeTabID == recordID)
    }

    @Test
    func paneProcessExited_in_normal_project_closes_as_before() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        fx.state.paneProcessExited(paneID, projectID: p.id)

        #expect(ws.tabs.isEmpty)
    }

    // MARK: - Persistence + materialize

    @Test
    func pinned_tabs_persist_and_restore_as_records_with_live_snapshots() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.saveWorkspaces()

        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        #expect(loaded.pinned.count == 1)
        #expect(loaded.pinned.first?.id == tab.id)
        #expect(loaded.pinned.first?.live != nil)
        #expect(loaded.pinned.first?.originProjectID == p.id)
        // The pinned workspace never serializes into the ordinary array.
        #expect(!loaded.workspaces.contains { $0.projectID == pinnedID })
    }

    @Test
    func materialize_respawns_dead_sessions_from_the_declaration() async throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        let originalSession = try #require(tab.splitRoot.allPanes().first?.sessionName)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.saveWorkspaces()

        // Second launch: a fresh state restoring the same file, with a zmx
        // whose listing says nothing survived. Pinned tabs are EAGER: the
        // dead tab respawns from its declaration at launch, not on click.
        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var dead = ZmxClient.noop
        dead.isBundled = { true }
        dead.listSessionsWithClients = { [] }
        state2.zmx = dead
        state2.warmPane = { _ in }
        state2.restorePinnedState(WorkspaceStore(fileURL: fx.storeURL).load().pinned)

        await state2.materializeRestoredPinnedTabs()

        #expect(state2.pinnedRecords.map(\.id) == [tab.id])
        #expect(state2.isPinnedTabLoaded(tab.id))
        // A respawn, not a reattach: fresh pane, fresh session identity.
        let pane = try #require(state2.pinnedWorkspace?.tabs.first?.splitRoot.allPanes().first)
        #expect(pane.sessionName != originalSession)
        #expect(pane.projectPath == "/tmp")
    }

    @Test
    func restoreSelection_starts_origin_bookmarks_before_pinned_warm() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-pinned-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))

        let projectsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-pinned-projects-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-pinned-groups-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: projectsURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        let projectStore = ProjectStore(fileURL: projectsURL, groupsFileURL: groupsURL)
        let project = projectStore.create(
            name: "origin",
            path: dir.path,
            securityScopedBookmark: bookmark
        )

        let fx = makeFixture()
        fx.state.selectProject(project)
        let tab = try #require(fx.state.workspaces[project.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: project.id)
        fx.state.saveWorkspaces()

        let prior = Preferences.shared.activeProjectID
        Preferences.shared.activeProjectID = pinnedID
        defer { Preferences.shared.activeProjectID = prior }

        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        state2.zmx = .noop
        state2.warmPane = { _ in }
        state2.restoreSelection(projects: projectStore.projects)

        #expect(state2.isHoldingSecurityScopedAccess(for: project.id))
        #expect(state2.pendingSecurityScopeRegrantID == nil)
    }

    @Test
    func materialize_eager_loads_declaration_only_records_and_warms_them() async throws {
        let fx = makeFixture()
        let recordID = UUID()
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: recordID,
            declaration: LayoutTab(
                name: "dev",
                layout: .pane(LayoutPane(cwd: "/tmp", run: "npm run dev"))
            ),
            originProjectID: nil
        )]
        var warmed: [UUID] = []
        fx.state.warmPane = { warmed.append($0.id) }

        await fx.state.materializeRestoredPinnedTabs()

        #expect(fx.state.isPinnedTabLoaded(recordID))
        let pane = try #require(fx.state.pinnedWorkspace?.tabs.first?.splitRoot.allPanes().first)
        #expect(pane.command == "npm run dev")
        #expect(warmed == [pane.id])
    }

    @Test
    func materialize_reattaches_surviving_sessions() async throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        let sessionName = try #require(tab.splitRoot.allPanes().first?.sessionName)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.saveWorkspaces()

        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var alive = ZmxClient.noop
        alive.isBundled = { true }
        alive.listSessionsWithClients = { [ZmxSessionListParser.Entry(name: sessionName, clients: 0)] }
        state2.zmx = alive
        state2.warmPane = { _ in }
        state2.restorePinnedState(WorkspaceStore(fileURL: fx.storeURL).load().pinned)

        await state2.materializeRestoredPinnedTabs()

        #expect(state2.isPinnedTabLoaded(tab.id))
        // Session identity survives the round trip verbatim.
        let restoredPane = try #require(state2.pinnedWorkspace?.tabs.first?.splitRoot.allPanes().first)
        #expect(restoredPane.sessionName == sessionName)
    }

    @Test
    func materialize_failed_listing_reattaches_conservatively() async throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.saveWorkspaces()

        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var unknown = ZmxClient.noop
        unknown.isBundled = { true }
        unknown.listSessionsWithClients = { nil } // probe failed → unknown
        state2.zmx = unknown
        state2.warmPane = { _ in }
        state2.restorePinnedState(WorkspaceStore(fileURL: fx.storeURL).load().pinned)

        await state2.materializeRestoredPinnedTabs()

        // Unknown must fail toward reattach, never toward respawn.
        #expect(state2.isPinnedTabLoaded(tab.id))
    }

    // MARK: - Declaration freshness

    @Test
    func foreground_change_schedules_a_declaration_refresh() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let pane = try #require(tab.splitRoot.allPanes().first)

        // First observation populates the stamp (counts as a change);
        // steady state schedules nothing; a new foreground does.
        #expect(fx.state.notePinnedForegroundChangesIfNeeded())
        #expect(fx.state.notePinnedForegroundChangesIfNeeded() == false)
        pane.foregroundProcessName = "btop"
        #expect(fx.state.notePinnedForegroundChangesIfNeeded())
        #expect(fx.state.notePinnedForegroundChangesIfNeeded() == false)
    }

    @Test
    func persistRefreshedPinnedDeclarations_recaptures_and_rewrites_the_file() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)

        // The declaration was captured at pin time; a later change to the tab
        // (a rename stands in for a started process, which needs a live
        // surface to observe) must reach both the record and pinned.yaml.
        tab.customTitle = "renamed"
        fx.state.persistRefreshedPinnedDeclarations()

        #expect(fx.state.pinnedRecords.first?.declaration.name == "renamed")
        let text = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(text.contains("renamed"))
    }

    // MARK: - Audit regressions

    @Test
    func declaration_refresh_never_erases_an_established_run() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        // The record was pinned with a run: (hand-set here; live capture in
        // tests always reads idle, which is exactly the hazard).
        fx.state.pinnedRecords[0].declaration = LayoutTab(
            name: nil, layout: .pane(LayoutPane(cwd: "/tmp", run: "npm run dev"))
        )

        fx.state.refreshPinnedDeclarationsFromLiveTabs()

        guard case let .pane(leaf) = fx.state.pinnedRecords[0].declaration.layout else {
            Issue.record("expected a leaf")
            return
        }
        #expect(leaf.run == "npm run dev")
    }

    @Test
    func pinned_active_tab_survives_a_restart() async throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let first = ws.tabs[0]
        let second = ws.createTab(projectPath: p.path)
        fx.state.pinTab(first.id, fromProject: p.id)
        fx.state.pinTab(second.id, fromProject: p.id)
        fx.state.selectPinnedTab(second.id)
        fx.state.saveWorkspaces()

        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        #expect(loaded.pinnedActiveTabID == second.id)

        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        // Computed on the main actor first — the client closure is @Sendable.
        let sessionEntries = [first, second].flatMap { $0.splitRoot.allPanes() }.map {
            ZmxSessionListParser.Entry(name: $0.sessionName, clients: 0)
        }
        var alive = ZmxClient.noop
        alive.isBundled = { true }
        alive.listSessionsWithClients = { sessionEntries }
        state2.zmx = alive
        state2.warmPane = { _ in }
        state2.restorePinnedState(loaded.pinned, activeTabID: loaded.pinnedActiveTabID)
        await state2.materializeRestoredPinnedTabs()

        #expect(state2.pinnedWorkspace?.activeTabID == second.id)
    }

    @Test
    func dragging_an_unloaded_record_into_a_project_spawns_it_there() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let recordID = UUID()
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: recordID,
            declaration: LayoutTab(name: "dev", layout: .pane(LayoutPane(cwd: "/tmp", run: "btop"))),
            originProjectID: nil
        )]

        fx.state.moveTab(recordID, from: pinnedID, to: p.id, destPath: p.path)

        #expect(fx.state.pinnedRecords.isEmpty)
        let moved = try #require(fx.state.workspaces[p.id]?.tabs.first { $0.id == recordID })
        #expect(moved.splitRoot.allPanes().first?.command == "btop")
        #expect(moved.splitRoot.allPanes().first?.projectID == p.id)
    }

    @Test
    func reorderTab_in_pinned_moves_the_record_too() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let first = ws.tabs[0]
        let second = ws.createTab(projectPath: p.path)
        fx.state.pinTab(first.id, fromProject: p.id)
        fx.state.pinTab(second.id, fromProject: p.id)

        // The CLI's live-tab drop offset: move `second` to the front.
        fx.state.reorderTab(second.id, inProject: pinnedID, toIndex: 0)

        #expect(fx.state.pinnedRecords.map(\.id) == [second.id, first.id])
        #expect(fx.state.pinnedWorkspace?.tabs.map(\.id) == [second.id, first.id])
    }

    @Test
    func selectTabByIndex_in_pinned_counts_sidebar_rows() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        // An UNLOADED record ahead of the loaded tab: index 0 must reach it.
        let unloadedID = UUID()
        fx.state.pinnedRecords.insert(PinnedTabRecord(
            id: unloadedID,
            declaration: LayoutTab(layout: .pane(LayoutPane(cwd: "/tmp", run: "btop"))),
            originProjectID: nil
        ), at: 0)

        fx.state.selectTabByIndex(0, projectID: pinnedID)

        #expect(fx.state.pinnedWorkspace?.activeTabID == unloadedID)
        #expect(fx.state.isPinnedTabLoaded(unloadedID))
    }

    @Test
    func project_cycling_steps_through_the_pinned_slot() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        #expect(fx.state.activeProjectID == pinnedID)

        fx.state.selectNextProject(projects: [p])
        #expect(fx.state.activeProjectID == p.id)

        fx.state.selectPreviousProject(projects: [p])
        #expect(fx.state.activeProjectID == pinnedID)
    }

    @Test
    func write_time_absorption_adopts_the_files_order() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let a = ws.tabs[0]
        let b = ws.createTab(projectPath: p.path)
        fx.state.pinTab(a.id, fromProject: p.id)
        fx.state.pinTab(b.id, fromProject: p.id)
        fx.state.pinnedRecords[0].declaration = LayoutTab(name: "a", layout: .pane(LayoutPane(cwd: "/tmp")))
        fx.state.pinnedRecords[1].declaration = LayoutTab(name: "b", layout: .pane(LayoutPane(cwd: "/tmp")))

        // Hand-reorder the file while the app runs, then trigger a write.
        try fx.state.pinnedLayoutStore.write(tabs: [
            fx.state.pinnedRecords[1].declaration,
            fx.state.pinnedRecords[0].declaration,
        ])
        fx.state.writePinnedLayout()

        #expect(fx.state.pinnedRecords.map(\.declaration.name) == ["b", "a"])
        #expect(fx.state.pinnedWorkspace?.tabs.map(\.id) == [b.id, a.id])
    }

    @Test
    func quit_never_creates_pinned_yaml_for_users_who_never_pinned() {
        let fx = makeFixture()
        _ = seedProject(fx.state)
        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        fx.state.persistForTermination()

        #expect(!FileManager.default.fileExists(atPath: fx.state.pinnedLayoutStore.fileURL.path))
    }

    @Test
    func separated_pane_lands_at_the_record_slot_the_drop_named() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        // An unloaded record occupies row 0; the drop names slot 1 (below it).
        let unloadedID = UUID()
        fx.state.pinnedRecords = [PinnedTabRecord(
            id: unloadedID,
            declaration: LayoutTab(name: "sleeper", layout: .pane(LayoutPane(cwd: "/tmp"))),
            originProjectID: nil
        )]
        fx.state.ensurePinnedWorkspace()
        let paneID = try #require(tab.split(paneID: tab.splitRoot.allPanes()[0].id, direction: .horizontal))

        fx.state.separatePaneIntoPinned(paneID, atRecordIndex: 1)

        #expect(fx.state.pinnedRecords.count == 2)
        #expect(fx.state.pinnedRecords[0].id == unloadedID)
        #expect(fx.state.pinnedRecords[1].id != unloadedID)
        #expect(fx.state.pinnedRecords[1].originProjectID == p.id)
        #expect(fx.state.pinnedRecords[1].originFolderPath == p.path)
    }

    @Test
    func separatePaneIntoPinned_keeps_source_folder_grant_on_mas() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-separate-pin-grant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let p = Project(name: "proj", path: dir.path, sortOrder: 0, securityScopedBookmark: bookmark)
        fx.state.selectProject(p)
        #expect(fx.state.isHoldingSecurityScopedAccess(for: p.id))
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        let paneID = try #require(tab.split(paneID: tab.splitRoot.allPanes()[0].id, direction: .horizontal))
        let pane = try #require(tab.splitRoot.findPane(id: paneID))

        fx.state.separatePaneIntoPinned(paneID, atRecordIndex: 0)

        let record = try #require(fx.state.pinnedRecords.first)
        #expect(record.originProjectID == p.id)
        #expect(record.originFolderPath == p.path)
        #expect(record.originFolderBookmark == bookmark)
        #expect(fx.state.isHoldingSecurityScopedAccess(for: p.id))
        #expect(fx.state.shouldSpawnPane(pane, workspaceID: PinnedTabs.projectID))
        #expect(fx.state.pendingSecurityScopeRegrantID != record.id)
    }

    @Test
    func merge_into_originless_pinned_stamps_source_origin() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-merge-pin-grant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        fx.state.ensurePinnedWorkspace()
        let destTabID = try #require(
            fx.state.createTab(projectID: PinnedTabs.projectID, projectPath: PinnedTabs.fallbackRoot)
        )
        let destRecord = try #require(fx.state.pinnedRecords.first { $0.id == destTabID })
        #expect(destRecord.originProjectID == nil)
        #expect(destRecord.originFolderPath == PinnedTabs.fallbackRoot)
        let homeBookmark = try #require(
            SecurityScopedBookmark.create(from: URL(fileURLWithPath: PinnedTabs.fallbackRoot))
        )
        if let i = fx.state.pinnedRecords.firstIndex(where: { $0.id == destTabID }) {
            fx.state.pinnedRecords[i].originFolderBookmark = homeBookmark
            fx.state.beginOriginlessPinnedFolderGrant(fx.state.pinnedRecords[i])
        }

        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let p = Project(name: "proj", path: dir.path, sortOrder: 0, securityScopedBookmark: bookmark)
        fx.state.selectProject(p)
        let sourceTab = try #require(fx.state.workspaces[p.id]?.activeTab)
        let sourcePane = try #require(sourceTab.splitRoot.allPanes().first)

        fx.state.mergeTab(
            sourceTab.id,
            from: p.id,
            at: .rootEdge(.bottom),
            inProject: PinnedTabs.projectID
        )

        let merged = try #require(fx.state.pinnedRecords.first { $0.id == destTabID })
        #expect(merged.originProjectID == p.id)
        #expect(merged.originFolderPath == p.path)
        #expect(merged.originFolderBookmark == bookmark)
        #expect(merged.originFolderBookmark != homeBookmark)
        #expect(merged.coveringGrants.contains { $0.id == destTabID && $0.folderPath == PinnedTabs.fallbackRoot })
        #expect(merged.coveringGrants.contains { $0.id == destTabID && $0.folderBookmark == homeBookmark })
        #expect(fx.state.isHoldingSecurityScopedAccess(for: p.id))
        #expect(fx.state.shouldSpawnPane(sourcePane, workspaceID: PinnedTabs.projectID))
        let homePane = try #require(
            fx.state.pinnedWorkspace?.tabs.first { $0.id == destTabID }?
                .splitRoot.allPanes().first { $0.projectPath == PinnedTabs.fallbackRoot }
        )
        #expect(fx.state.shouldSpawnPane(homePane, workspaceID: PinnedTabs.projectID))
    }

    @Test
    func merge_into_pinned_from_other_folder_covers_incoming_pane_cwd() throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-merge-pin-a-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-merge-pin-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        let bookmarkA = try #require(SecurityScopedBookmark.create(from: dirA))
        let bookmarkB = try #require(SecurityScopedBookmark.create(from: dirB))
        let a = Project(name: "a", path: dirA.path, sortOrder: 0, securityScopedBookmark: bookmarkA)
        let b = Project(name: "b", path: dirB.path, sortOrder: 1, securityScopedBookmark: bookmarkB)
        fx.state.selectProject(a)
        let aTab = try #require(fx.state.workspaces[a.id]?.activeTab)
        let aPane = try #require(aTab.splitRoot.allPanes().first)
        fx.state.pinTab(aTab.id, fromProject: a.id)
        fx.state.selectProject(b)
        let bTab = try #require(fx.state.workspaces[b.id]?.activeTab)
        let bPane = try #require(bTab.splitRoot.allPanes().first)

        fx.state.mergeTab(
            bTab.id,
            from: b.id,
            at: .rootEdge(.bottom),
            inProject: PinnedTabs.projectID
        )

        let merged = try #require(fx.state.pinnedRecords.first { $0.id == aTab.id })
        #expect(merged.originProjectID == a.id)
        #expect(merged.originFolderPath == a.path)
        #expect(merged.originFolderBookmark == bookmarkA)
        #expect(merged.coveringGrants.contains { $0.id == b.id && $0.folderPath == b.path })
        #expect(merged.coveringGrants.contains { $0.id == b.id && $0.folderBookmark == bookmarkB })
        #expect(fx.state.isHoldingSecurityScopedAccess(for: a.id))
        #expect(fx.state.isHoldingSecurityScopedAccess(for: b.id))
        #expect(fx.state.shouldSpawnPane(aPane, workspaceID: PinnedTabs.projectID))
        #expect(fx.state.shouldSpawnPane(bPane, workspaceID: PinnedTabs.projectID))

        fx.state.unloadProject(b.id)
        #expect(fx.state.isHoldingSecurityScopedAccess(for: b.id))
        #expect(fx.state.shouldSpawnPane(bPane, workspaceID: PinnedTabs.projectID))
    }

    @Test
    func origin_regrant_does_not_kill_covering_grant_panes() throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-regrant-a-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-regrant-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        let killed = OSAllocatedUnfairLock(initialState: [String]())
        fx.state.zmx = ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { name in killed.withLock { $0.append(name) } },
            killRemoteSession: { _, _, _ in },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { [] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [], leaders: [:]) }
        )
        let bookmarkA = try #require(SecurityScopedBookmark.create(from: dirA))
        let bookmarkB = try #require(SecurityScopedBookmark.create(from: dirB))
        let a = Project(name: "a", path: dirA.path, sortOrder: 0, securityScopedBookmark: bookmarkA)
        let b = Project(name: "b", path: dirB.path, sortOrder: 1, securityScopedBookmark: bookmarkB)
        fx.state.selectProject(a)
        let aTab = try #require(fx.state.workspaces[a.id]?.activeTab)
        let aPane = try #require(aTab.splitRoot.allPanes().first)
        fx.state.pinTab(aTab.id, fromProject: a.id)
        fx.state.selectProject(b)
        let bTab = try #require(fx.state.workspaces[b.id]?.activeTab)
        let bPane = try #require(bTab.splitRoot.allPanes().first)
        fx.state.mergeTab(
            bTab.id,
            from: b.id,
            at: .rootEdge(.bottom),
            inProject: PinnedTabs.projectID
        )
        _ = aPane.ensureNSView()
        _ = bPane.ensureNSView()
        #expect(bPane.nsView != nil)

        let store = ProjectStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-regrant-projects-\(UUID().uuidString).json"),
            groupsFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-regrant-groups-\(UUID().uuidString).json")
        )
        store.add(a)
        store.add(b)
        fx.state.pendingSecurityScopeRegrantID = nil
        let outcome = fx.state.completeSecurityScopeRegrant(
            store: store,
            projectID: a.id,
            pickedURL: URL(fileURLWithPath: dirA.path)
        )
        #expect(outcome == .granted)
        #expect(bPane.nsView != nil)
        #expect(!killed.withLock { $0 }.contains(bPane.sessionName))
        #expect(fx.state.shouldSpawnPane(bPane, workspaceID: PinnedTabs.projectID))
    }

    @Test
    func restore_starts_covering_grants_after_materialize() async throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-cover-a-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-cover-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        let bookmarkA = try #require(SecurityScopedBookmark.create(from: dirA))
        let bookmarkB = try #require(SecurityScopedBookmark.create(from: dirB))
        let a = Project(name: "a", path: dirA.path, sortOrder: 0, securityScopedBookmark: bookmarkA)
        let b = Project(name: "b", path: dirB.path, sortOrder: 1, securityScopedBookmark: bookmarkB)
        fx.state.selectProject(a)
        let aTab = try #require(fx.state.workspaces[a.id]?.activeTab)
        fx.state.pinTab(aTab.id, fromProject: a.id)
        fx.state.selectProject(b)
        let bTab = try #require(fx.state.workspaces[b.id]?.activeTab)
        fx.state.mergeTab(
            bTab.id,
            from: b.id,
            at: .rootEdge(.bottom),
            inProject: PinnedTabs.projectID
        )
        fx.state.saveWorkspaces()

        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var unknown = ZmxClient.noop
        unknown.isBundled = { true }
        unknown.listSessionsWithClients = { nil }
        state2.zmx = unknown
        state2.warmPane = { _ in }
        state2.folderGrantUsesSecurityScope = true
        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        state2.restorePinnedState(loaded.pinned)
        #expect(state2.pinnedRecords.first?.coveringGrants.contains { $0.id == b.id } == true)

        await state2.materializeRestoredPinnedTabs(projects: [a, b])
        state2.beginSecurityScopedAccessForPinnedOrigins(projects: [a, b])

        let restored = try #require(state2.pinnedWorkspace?.tabs.first { $0.id == aTab.id })
        let restoredA = try #require(restored.splitRoot.allPanes().first { $0.projectPath == a.path })
        let restoredB = try #require(restored.splitRoot.allPanes().first { $0.projectPath == b.path })
        #expect(state2.isHoldingSecurityScopedAccess(for: a.id))
        #expect(state2.isHoldingSecurityScopedAccess(for: b.id))
        #expect(state2.shouldSpawnPane(restoredA, workspaceID: PinnedTabs.projectID))
        #expect(state2.shouldSpawnPane(restoredB, workspaceID: PinnedTabs.projectID))

        let state3 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var unknown3 = ZmxClient.noop
        unknown3.isBundled = { true }
        unknown3.listSessionsWithClients = { nil }
        state3.zmx = unknown3
        state3.warmPane = { _ in }
        state3.folderGrantUsesSecurityScope = true
        state3.restorePinnedState(loaded.pinned)
        await state3.materializeRestoredPinnedTabs(projects: [])
        state3.beginSecurityScopedAccessForPinnedOrigins(projects: [])
        let restored3 = try #require(state3.pinnedWorkspace?.tabs.first { $0.id == aTab.id })
        let restored3B = try #require(restored3.splitRoot.allPanes().first { $0.projectPath == b.path })
        #expect(state3.isHoldingSecurityScopedAccess(for: b.id))
        #expect(state3.shouldSpawnPane(restored3B, workspaceID: PinnedTabs.projectID))
        #expect(state3.pendingSecurityScopeRegrantID != b.id)

        let state4 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var unknown4 = ZmxClient.noop
        unknown4.isBundled = { true }
        unknown4.listSessionsWithClients = { nil }
        state4.zmx = unknown4
        state4.warmPane = { _ in }
        state4.folderGrantUsesSecurityScope = true
        state4.restorePinnedState(loaded.pinned)
        if let i = state4.pinnedRecords.firstIndex(where: { $0.id == aTab.id }),
           let j = state4.pinnedRecords[i].coveringGrants.firstIndex(where: { $0.id == b.id })
        {
            state4.pinnedRecords[i].coveringGrants[j].folderBookmark = nil
        }
        await state4.materializeRestoredPinnedTabs(projects: [])
        state4.beginSecurityScopedAccessForPinnedOrigins(projects: [])
        #expect(state4.pendingSecurityScopeRegrantID == b.id)
        let restored4B = try #require(
            state4.pinnedWorkspace?.tabs.first { $0.id == aTab.id }?
                .splitRoot.allPanes().first { $0.projectPath == b.path }
        )
        #expect(!state4.shouldSpawnPane(restored4B, workspaceID: PinnedTabs.projectID))
        let store = ProjectStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-cover-projects-\(UUID().uuidString).json"),
            groupsFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-cover-groups-\(UUID().uuidString).json")
        )
        let outcome = state4.completeSecurityScopeRegrant(
            store: store,
            projectID: b.id,
            pickedURL: dirB
        )
        #expect(outcome == .granted)
        #expect(state4.shouldSpawnPane(restored4B, workspaceID: PinnedTabs.projectID))
    }

    @Test
    func restore_keeps_dest_home_grant_after_origin_replace() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-home-leftover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        fx.state.ensurePinnedWorkspace()
        let destTabID = try #require(
            fx.state.createTab(projectID: PinnedTabs.projectID, projectPath: PinnedTabs.fallbackRoot)
        )
        let homeBookmark = try #require(
            SecurityScopedBookmark.create(from: URL(fileURLWithPath: PinnedTabs.fallbackRoot))
        )
        if let i = fx.state.pinnedRecords.firstIndex(where: { $0.id == destTabID }) {
            fx.state.pinnedRecords[i].originFolderBookmark = homeBookmark
            fx.state.beginOriginlessPinnedFolderGrant(fx.state.pinnedRecords[i])
        }
        let destHomePane = try #require(
            fx.state.pinnedWorkspace?.tabs.first { $0.id == destTabID }?
                .splitRoot.allPanes().first { $0.projectPath == PinnedTabs.fallbackRoot }
        )

        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let p = Project(name: "proj", path: dir.path, sortOrder: 0, securityScopedBookmark: bookmark)
        fx.state.selectProject(p)
        let sourceTab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.mergeTab(
            sourceTab.id,
            from: p.id,
            at: .rootEdge(.bottom),
            inProject: PinnedTabs.projectID
        )
        #expect(fx.state.shouldSpawnPane(destHomePane, workspaceID: PinnedTabs.projectID))
        fx.state.saveWorkspaces()

        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var unknown = ZmxClient.noop
        unknown.isBundled = { true }
        unknown.listSessionsWithClients = { nil }
        state2.zmx = unknown
        state2.warmPane = { _ in }
        state2.folderGrantUsesSecurityScope = true
        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        state2.restorePinnedState(loaded.pinned)
        await state2.materializeRestoredPinnedTabs(projects: [p])
        state2.beginSecurityScopedAccessForPinnedOrigins(projects: [p])

        let restored = try #require(state2.pinnedWorkspace?.tabs.first { $0.id == destTabID })
        let restoredHome = try #require(
            restored.splitRoot.allPanes().first { $0.projectPath == PinnedTabs.fallbackRoot }
        )
        let restoredOrigin = try #require(
            restored.splitRoot.allPanes().first { $0.projectPath == p.path }
        )
        #expect(state2.pinnedRecords.first?.coveringGrants.contains {
            $0.id == destTabID && $0.folderPath == PinnedTabs.fallbackRoot
        } == true)
        #expect(state2.isHoldingSecurityScopedAccess(for: destTabID))
        #expect(state2.isHoldingSecurityScopedAccess(for: p.id))
        #expect(state2.shouldSpawnPane(restoredHome, workspaceID: PinnedTabs.projectID))
        #expect(state2.shouldSpawnPane(restoredOrigin, workspaceID: PinnedTabs.projectID))
    }

    @Test
    func dest_home_and_origin_shrink_leftovers_keep_distinct_covering_grants() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-home-shrink-\(UUID().uuidString)", isDirectory: true)
        let child = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        fx.state.ensurePinnedWorkspace()
        let destTabID = try #require(
            fx.state.createTab(projectID: PinnedTabs.projectID, projectPath: PinnedTabs.fallbackRoot)
        )
        let homeBookmark = try #require(
            SecurityScopedBookmark.create(from: URL(fileURLWithPath: PinnedTabs.fallbackRoot))
        )
        if let i = fx.state.pinnedRecords.firstIndex(where: { $0.id == destTabID }) {
            fx.state.pinnedRecords[i].originFolderBookmark = homeBookmark
            fx.state.beginOriginlessPinnedFolderGrant(fx.state.pinnedRecords[i])
        }
        let destHomePane = try #require(
            fx.state.pinnedWorkspace?.tabs.first { $0.id == destTabID }?
                .splitRoot.allPanes().first { $0.projectPath == PinnedTabs.fallbackRoot }
        )

        let store = ProjectStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-home-shrink-projects-\(UUID().uuidString).json"),
            groupsFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-home-shrink-groups-\(UUID().uuidString).json")
        )
        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let p = store.create(name: "proj", path: dir.path, securityScopedBookmark: bookmark)
        fx.state.selectProject(p)
        let sourceTab = try #require(fx.state.workspaces[p.id]?.activeTab)
        let originPane = try #require(sourceTab.splitRoot.allPanes().first)
        let leftoverOriginPath = originPane.projectPath
        #expect(SecurityScopedBookmark.folder(dir.path, covers: leftoverOriginPath))
        #expect(!SecurityScopedBookmark.folder(child.path, covers: leftoverOriginPath))
        #expect(!SecurityScopedBookmark.folder(PinnedTabs.fallbackRoot, covers: leftoverOriginPath))

        fx.state.mergeTab(
            sourceTab.id,
            from: p.id,
            at: .rootEdge(.bottom),
            inProject: PinnedTabs.projectID
        )
        #expect(fx.state.shouldSpawnPane(destHomePane, workspaceID: PinnedTabs.projectID))
        #expect(fx.state.shouldSpawnPane(originPane, workspaceID: PinnedTabs.projectID))

        #expect(fx.state.commitReplacedProjectPath(
            projectStore: store,
            projectID: p.id,
            newPath: child.path,
            pickedURL: nil
        ))

        let record = try #require(fx.state.pinnedRecords.first { $0.id == destTabID })
        let homeGrant = try #require(record.coveringGrants.first {
            SecurityScopedBookmark.folder($0.folderPath, covers: PinnedTabs.fallbackRoot)
        })
        let originGrant = try #require(record.coveringGrants.first {
            SecurityScopedBookmark.folder($0.folderPath, covers: leftoverOriginPath)
        })
        #expect(homeGrant.id != originGrant.id)
        #expect(homeGrant.folderBookmark == homeBookmark)
        #expect(originGrant.folderBookmark == bookmark)
        #expect(
            fx.state.shouldSpawnPane(destHomePane, workspaceID: PinnedTabs.projectID)
                || fx.state.pendingSecurityScopeRegrantID == homeGrant.id
        )
        #expect(
            fx.state.shouldSpawnPane(originPane, workspaceID: PinnedTabs.projectID)
                || fx.state.pendingSecurityScopeRegrantID == originGrant.id
        )

        fx.state.saveWorkspaces()
        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var unknown = ZmxClient.noop
        unknown.isBundled = { true }
        unknown.listSessionsWithClients = { nil }
        state2.zmx = unknown
        state2.warmPane = { _ in }
        state2.folderGrantUsesSecurityScope = true
        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        state2.restorePinnedState(loaded.pinned)
        let updated = try #require(store.projects.first { $0.id == p.id })
        await state2.materializeRestoredPinnedTabs(projects: [updated])
        state2.beginSecurityScopedAccessForPinnedOrigins(projects: [updated])

        let restored = try #require(state2.pinnedWorkspace?.tabs.first { $0.id == destTabID })
        let restoredHome = try #require(
            restored.splitRoot.allPanes().first { $0.projectPath == PinnedTabs.fallbackRoot }
        )
        let restoredOrigin = try #require(
            restored.splitRoot.allPanes().first { $0.projectPath == leftoverOriginPath }
        )
        let restoredRecord = try #require(state2.pinnedRecords.first { $0.id == destTabID })
        let restoredHomeGrant = try #require(restoredRecord.coveringGrants.first {
            SecurityScopedBookmark.folder($0.folderPath, covers: PinnedTabs.fallbackRoot)
        })
        let restoredOriginGrant = try #require(restoredRecord.coveringGrants.first {
            SecurityScopedBookmark.folder($0.folderPath, covers: leftoverOriginPath)
        })
        #expect(restoredHomeGrant.id != restoredOriginGrant.id)
        #expect(
            state2.shouldSpawnPane(restoredHome, workspaceID: PinnedTabs.projectID)
                || state2.pendingSecurityScopeRegrantID == restoredHomeGrant.id
        )
        #expect(
            state2.shouldSpawnPane(restoredOrigin, workspaceID: PinnedTabs.projectID)
                || state2.pendingSecurityScopeRegrantID == restoredOriginGrant.id
        )
    }

    @Test
    func dest_home_covering_shrink_leftover_keeps_distinct_covering_grants() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-home-cover-\(UUID().uuidString)", isDirectory: true)
        let dir = parent.appendingPathComponent("repo", isDirectory: true)
        let child = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        fx.state.ensurePinnedWorkspace()
        let destTabID = try #require(
            fx.state.createTab(projectID: PinnedTabs.projectID, projectPath: parent.path)
        )
        if let i = fx.state.pinnedRecords.firstIndex(where: { $0.id == destTabID }) {
            fx.state.pinnedRecords[i].originFolderBookmark = nil
            fx.state.beginOriginlessPinnedFolderGrant(fx.state.pinnedRecords[i])
        }
        let destHomePane = try #require(
            fx.state.pinnedWorkspace?.tabs.first { $0.id == destTabID }?
                .splitRoot.allPanes().first { $0.projectPath == parent.path }
        )

        let store = ProjectStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-home-cover-projects-\(UUID().uuidString).json"),
            groupsFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-home-cover-groups-\(UUID().uuidString).json")
        )
        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let p = store.create(name: "proj", path: dir.path, securityScopedBookmark: bookmark)
        fx.state.selectProject(p)
        let sourceTab = try #require(fx.state.workspaces[p.id]?.activeTab)
        let originPane = try #require(sourceTab.splitRoot.allPanes().first)
        let leftoverOriginPath = originPane.projectPath
        #expect(SecurityScopedBookmark.folder(parent.path, covers: leftoverOriginPath))
        #expect(SecurityScopedBookmark.folder(dir.path, covers: leftoverOriginPath))
        #expect(!SecurityScopedBookmark.folder(child.path, covers: leftoverOriginPath))
        #expect(!SecurityScopedBookmark.folder(leftoverOriginPath, covers: parent.path))

        fx.state.mergeTab(
            sourceTab.id,
            from: p.id,
            at: .rootEdge(.bottom),
            inProject: PinnedTabs.projectID
        )

        #expect(fx.state.commitReplacedProjectPath(
            projectStore: store,
            projectID: p.id,
            newPath: child.path,
            pickedURL: nil
        ))

        let record = try #require(fx.state.pinnedRecords.first { $0.id == destTabID })
        let homeGrant = try #require(record.coveringGrants.first {
            SecurityScopedBookmark.folder($0.folderPath, covers: parent.path)
                && SecurityScopedBookmark.folder(parent.path, covers: $0.folderPath)
        })
        let originGrant = try #require(record.coveringGrants.first {
            SecurityScopedBookmark.folder($0.folderPath, covers: leftoverOriginPath)
                && $0.id != homeGrant.id
        })
        #expect(homeGrant.folderBookmark != bookmark)
        #expect(originGrant.folderBookmark == bookmark)
        #expect(
            fx.state.shouldSpawnPane(destHomePane, workspaceID: PinnedTabs.projectID)
                || fx.state.pendingSecurityScopeRegrantID == homeGrant.id
        )
        #expect(
            fx.state.shouldSpawnPane(originPane, workspaceID: PinnedTabs.projectID)
                || fx.state.pendingSecurityScopeRegrantID == originGrant.id
        )

        fx.state.saveWorkspaces()
        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var unknown = ZmxClient.noop
        unknown.isBundled = { true }
        unknown.listSessionsWithClients = { nil }
        state2.zmx = unknown
        state2.warmPane = { _ in }
        state2.folderGrantUsesSecurityScope = true
        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        state2.restorePinnedState(loaded.pinned)
        let updated = try #require(store.projects.first { $0.id == p.id })
        await state2.materializeRestoredPinnedTabs(projects: [updated])
        state2.beginSecurityScopedAccessForPinnedOrigins(projects: [updated])

        let restored = try #require(state2.pinnedWorkspace?.tabs.first { $0.id == destTabID })
        let restoredHome = try #require(
            restored.splitRoot.allPanes().first { $0.projectPath == parent.path }
        )
        let restoredOrigin = try #require(
            restored.splitRoot.allPanes().first { $0.projectPath == leftoverOriginPath }
        )
        let restoredRecord = try #require(state2.pinnedRecords.first { $0.id == destTabID })
        let restoredHomeGrant = try #require(restoredRecord.coveringGrants.first {
            SecurityScopedBookmark.folder($0.folderPath, covers: parent.path)
                && SecurityScopedBookmark.folder(parent.path, covers: $0.folderPath)
        })
        let restoredOriginGrant = try #require(restoredRecord.coveringGrants.first {
            SecurityScopedBookmark.folder($0.folderPath, covers: leftoverOriginPath)
                && $0.id != restoredHomeGrant.id
        })
        #expect(restoredHomeGrant.folderBookmark != bookmark)
        #expect(
            state2.shouldSpawnPane(restoredHome, workspaceID: PinnedTabs.projectID)
                || state2.pendingSecurityScopeRegrantID == restoredHomeGrant.id
        )
        #expect(
            state2.shouldSpawnPane(restoredOrigin, workspaceID: PinnedTabs.projectID)
                || state2.pendingSecurityScopeRegrantID == restoredOriginGrant.id
        )
    }

    @Test
    func pinTab_persists_covering_grants_for_extra_pane_cwds() async throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-pin-extra-a-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-pin-extra-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        let bookmarkA = try #require(SecurityScopedBookmark.create(from: dirA))
        let bookmarkB = try #require(SecurityScopedBookmark.create(from: dirB))
        let a = Project(name: "a", path: dirA.path, sortOrder: 0, securityScopedBookmark: bookmarkA)
        let b = Project(name: "b", path: dirB.path, sortOrder: 1, securityScopedBookmark: bookmarkB)
        fx.state.selectProject(a)
        let aTab = try #require(fx.state.workspaces[a.id]?.activeTab)
        fx.state.selectProject(b)
        let bTab = try #require(fx.state.workspaces[b.id]?.activeTab)
        let bPane = try #require(bTab.splitRoot.allPanes().first)

        fx.state.selectProject(a)
        fx.state.mergeTab(
            bTab.id,
            from: b.id,
            at: .rootEdge(.top),
            inProject: a.id
        )
        #expect(aTab.splitRoot.allPanes().first?.projectPath == b.path)
        fx.state.pinTab(aTab.id, fromProject: a.id)

        let pinned = try #require(fx.state.pinnedRecords.first { $0.id == aTab.id })
        #expect(pinned.originProjectID == a.id)
        #expect(pinned.originFolderPath == a.path)
        #expect(pinned.originFolderBookmark == bookmarkA)
        #expect(pinned.coveringGrants.contains { $0.id == b.id && $0.folderPath == b.path })
        #expect(pinned.coveringGrants.contains { $0.id == b.id && $0.folderBookmark == bookmarkB })
        #expect(!pinned.coveringGrants.contains { $0.id == a.id })
        #expect(fx.state.shouldSpawnPane(bPane, workspaceID: PinnedTabs.projectID))

        fx.state.saveWorkspaces()
        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var unknown = ZmxClient.noop
        unknown.isBundled = { true }
        unknown.listSessionsWithClients = { nil }
        state2.zmx = unknown
        state2.warmPane = { _ in }
        state2.folderGrantUsesSecurityScope = true
        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        state2.restorePinnedState(loaded.pinned)
        await state2.materializeRestoredPinnedTabs(projects: [a])
        state2.beginSecurityScopedAccessForPinnedOrigins(projects: [a])

        let restored = try #require(state2.pinnedWorkspace?.tabs.first { $0.id == aTab.id })
        let restoredB = try #require(restored.splitRoot.allPanes().first { $0.projectPath == b.path })
        #expect(state2.pinnedRecords.first?.coveringGrants.contains { $0.id == b.id } == true)
        #expect(state2.isHoldingSecurityScopedAccess(for: b.id))
        #expect(state2.shouldSpawnPane(restoredB, workspaceID: PinnedTabs.projectID))
        #expect(state2.pendingSecurityScopeRegrantID != b.id)
    }

    @Test
    func pinTab_persists_covering_grants_when_merged_pane_is_first_on_left() throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-pin-left-a-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-pin-left-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        let bookmarkA = try #require(SecurityScopedBookmark.create(from: dirA))
        let bookmarkB = try #require(SecurityScopedBookmark.create(from: dirB))
        let a = Project(name: "a", path: dirA.path, sortOrder: 0, securityScopedBookmark: bookmarkA)
        let b = Project(name: "b", path: dirB.path, sortOrder: 1, securityScopedBookmark: bookmarkB)
        fx.state.selectProject(a)
        let aTab = try #require(fx.state.workspaces[a.id]?.activeTab)
        fx.state.selectProject(b)
        let bTab = try #require(fx.state.workspaces[b.id]?.activeTab)
        let bPane = try #require(bTab.splitRoot.allPanes().first)

        fx.state.selectProject(a)
        fx.state.mergeTab(
            bTab.id,
            from: b.id,
            at: .rootEdge(.left),
            inProject: a.id
        )
        #expect(aTab.splitRoot.allPanes().first?.projectPath == b.path)
        fx.state.pinTab(aTab.id, fromProject: a.id)

        let pinned = try #require(fx.state.pinnedRecords.first { $0.id == aTab.id })
        #expect(pinned.originFolderPath == a.path)
        #expect(pinned.coveringGrants.contains { $0.id == b.id && $0.folderPath == b.path })
        #expect(fx.state.shouldSpawnPane(bPane, workspaceID: PinnedTabs.projectID))
    }

    @Test
    func separatePaneIntoPinned_stamps_origin_folder_from_source_project_not_pane_cwd() throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-sep-pin-a-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-sep-pin-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        let bookmarkA = try #require(SecurityScopedBookmark.create(from: dirA))
        let bookmarkB = try #require(SecurityScopedBookmark.create(from: dirB))
        let a = Project(name: "a", path: dirA.path, sortOrder: 0, securityScopedBookmark: bookmarkA)
        let b = Project(name: "b", path: dirB.path, sortOrder: 1, securityScopedBookmark: bookmarkB)
        fx.state.selectProject(a)
        let aTab = try #require(fx.state.workspaces[a.id]?.activeTab)
        fx.state.selectProject(b)
        let bTab = try #require(fx.state.workspaces[b.id]?.activeTab)
        let bPane = try #require(bTab.splitRoot.allPanes().first)

        fx.state.selectProject(a)
        fx.state.mergeTab(
            bTab.id,
            from: b.id,
            at: .rootEdge(.top),
            inProject: a.id
        )
        #expect(aTab.splitRoot.allPanes().first?.id == bPane.id)
        fx.state.separatePaneIntoPinned(bPane.id, atRecordIndex: 0)

        let record = try #require(fx.state.pinnedRecords.first { $0.id != aTab.id })
        #expect(record.originProjectID == a.id)
        #expect(record.originFolderPath == a.path)
        #expect(record.originFolderBookmark == bookmarkA)
        #expect(record.coveringGrants.contains { $0.id == b.id && $0.folderPath == b.path })
        #expect(record.coveringGrants.contains { $0.id == b.id && $0.folderBookmark == bookmarkB })
        #expect(fx.state.shouldSpawnPane(bPane, workspaceID: PinnedTabs.projectID))
        #expect(fx.state.isHoldingSecurityScopedAccess(for: b.id))
    }

    @Test
    func split_and_grid_in_pinned_queue_covering_grant_for_cwd_outside_origin() throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-split-pin-a-\(UUID().uuidString)", isDirectory: true)
        let extra = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-split-pin-extra-\(UUID().uuidString)", isDirectory: true)
        let extraGrid = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-grid-pin-extra-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extraGrid, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: extra)
            try? FileManager.default.removeItem(at: extraGrid)
        }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        let bookmarkA = try #require(SecurityScopedBookmark.create(from: dirA))
        let a = Project(name: "a", path: dirA.path, sortOrder: 0, securityScopedBookmark: bookmarkA)
        fx.state.selectProject(a)
        let aTab = try #require(fx.state.workspaces[a.id]?.activeTab)
        fx.state.pinTab(aTab.id, fromProject: a.id)
        fx.state.pendingSecurityScopeRegrantID = nil

        let originPane = try #require(aTab.splitRoot.allPanes().first)
        let drifted = Pane(projectPath: extra.path, projectID: PinnedTabs.projectID)
        aTab.splitRoot = .split(SplitBranch(
            direction: .horizontal,
            first: .pane(originPane),
            second: .pane(drifted)
        ))
        aTab.focusedPaneID = drifted.id
        fx.state.splitPane(direction: .vertical, projectID: PinnedTabs.projectID)

        let splitGrant = try #require(
            fx.state.pinnedRecords.first?.coveringGrants.first { $0.folderPath == extra.path }
        )
        let splitPane = try #require(aTab.splitRoot.allPanes().first { $0.projectPath == extra.path })
        #expect(!fx.state.shouldSpawnPane(splitPane, workspaceID: PinnedTabs.projectID))
        #expect(fx.state.pendingSecurityScopeRegrantID == splitGrant.id)

        let gridPane = Pane(projectPath: extraGrid.path, projectID: PinnedTabs.projectID)
        aTab.splitRoot = .split(SplitBranch(
            direction: .vertical,
            first: aTab.splitRoot,
            second: .pane(gridPane)
        ))
        fx.state.makeGrid(gridPane.id, rows: 1, columns: 2, projectID: PinnedTabs.projectID)
        let gridGrant = try #require(
            fx.state.pinnedRecords.first?.coveringGrants.first { $0.folderPath == extraGrid.path }
        )
        #expect(!fx.state.shouldSpawnPane(gridPane, workspaceID: PinnedTabs.projectID))
        #expect(
            fx.state.pendingSecurityScopeRegrantID == splitGrant.id
                || fx.state.pendingSecurityScopeRegrantID == gridGrant.id
        )

        let store = ProjectStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-split-pin-projects-\(UUID().uuidString).json"),
            groupsFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("futuraterm-split-pin-groups-\(UUID().uuidString).json")
        )
        fx.state.pendingSecurityScopeRegrantID = nil
        let outcome = fx.state.completeSecurityScopeRegrant(
            store: store,
            projectID: splitGrant.id,
            pickedURL: extra
        )
        #expect(outcome == .granted)
        #expect(fx.state.shouldSpawnPane(splitPane, workspaceID: PinnedTabs.projectID))
    }

    @Test
    func merge_originless_into_originated_pinned_persists_incoming_leftover() async throws {
        let dirA = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-originless-merge-a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirA) }

        let fx = makeFixture()
        fx.state.folderGrantUsesSecurityScope = true
        let bookmarkA = try #require(SecurityScopedBookmark.create(from: dirA))
        let a = Project(name: "a", path: dirA.path, sortOrder: 0, securityScopedBookmark: bookmarkA)
        fx.state.selectProject(a)
        let aTab = try #require(fx.state.workspaces[a.id]?.activeTab)
        fx.state.pinTab(aTab.id, fromProject: a.id)

        let cmdT = try #require(
            fx.state.createTab(projectID: PinnedTabs.projectID, projectPath: PinnedTabs.fallbackRoot)
        )
        let homeBookmark = try #require(
            SecurityScopedBookmark.create(from: URL(fileURLWithPath: PinnedTabs.fallbackRoot))
        )
        if let i = fx.state.pinnedRecords.firstIndex(where: { $0.id == cmdT }) {
            fx.state.pinnedRecords[i].originFolderBookmark = homeBookmark
            fx.state.beginOriginlessPinnedFolderGrant(fx.state.pinnedRecords[i])
        }
        let homePane = try #require(
            fx.state.pinnedWorkspace?.tabs.first { $0.id == cmdT }?
                .splitRoot.allPanes().first { $0.projectPath == PinnedTabs.fallbackRoot }
        )

        fx.state.selectPinnedTab(aTab.id)
        fx.state.mergeTab(
            cmdT,
            from: PinnedTabs.projectID,
            at: .rootEdge(.bottom),
            inProject: PinnedTabs.projectID
        )

        let merged = try #require(fx.state.pinnedRecords.first { $0.id == aTab.id })
        #expect(merged.originProjectID == a.id)
        #expect(merged.coveringGrants.contains {
            $0.id == cmdT && $0.folderPath == PinnedTabs.fallbackRoot && $0.folderBookmark == homeBookmark
        })
        #expect(fx.state.shouldSpawnPane(homePane, workspaceID: PinnedTabs.projectID))
        fx.state.saveWorkspaces()

        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        var unknown = ZmxClient.noop
        unknown.isBundled = { true }
        unknown.listSessionsWithClients = { nil }
        state2.zmx = unknown
        state2.warmPane = { _ in }
        state2.folderGrantUsesSecurityScope = true
        let loaded = WorkspaceStore(fileURL: fx.storeURL).load()
        state2.restorePinnedState(loaded.pinned)
        await state2.materializeRestoredPinnedTabs(projects: [a])
        state2.beginSecurityScopedAccessForPinnedOrigins(projects: [a])

        let restored = try #require(state2.pinnedWorkspace?.tabs.first { $0.id == aTab.id })
        let restoredHome = try #require(
            restored.splitRoot.allPanes().first { $0.projectPath == PinnedTabs.fallbackRoot }
        )
        #expect(state2.pinnedRecords.first?.coveringGrants.contains {
            $0.id == cmdT && $0.folderPath == PinnedTabs.fallbackRoot
        } == true)
        #expect(state2.isHoldingSecurityScopedAccess(for: cmdT))
        #expect(state2.shouldSpawnPane(restoredHome, workspaceID: PinnedTabs.projectID))
    }

    // MARK: - pinned.yaml reconcile / absorb

    @Test
    func launch_reconcile_adds_file_entries_as_unloaded_records() throws {
        let fx = makeFixture()
        try fx.state.pinnedLayoutStore.write(tabs: [
            LayoutTab(name: "hand-added", layout: .pane(LayoutPane(cwd: "~/dev", run: "btop"))),
        ])

        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        #expect(fx.state.pinnedRecords.count == 1)
        #expect(fx.state.pinnedRecords.first?.declaration.name == "hand-added")
        #expect(fx.state.isPinnedTabLoaded(fx.state.pinnedRecords[0].id) == false)
    }

    @Test
    func launch_reconcile_drops_unloaded_records_removed_from_file() throws {
        let fx = makeFixture()
        let keep = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "keep", layout: .pane(LayoutPane())),
            originProjectID: nil
        )
        let removed = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "removed", layout: .pane(LayoutPane())),
            originProjectID: nil
        )
        fx.state.pinnedRecords = [keep, removed]
        try fx.state.pinnedLayoutStore.write(tabs: [keep.declaration])

        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        #expect(fx.state.pinnedRecords.map(\.id) == [keep.id])
    }

    @Test
    func launch_reconcile_unpins_restorable_live_tab_removed_from_file() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        fx.state.saveWorkspaces()

        // Next launch: the user deleted the entry while the app was closed.
        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: fx.storeURL),
            projectFiles: ProjectFileStore(directoryURL: fx.projectsDir)
        )
        state2.zmx = .noop
        try state2.pinnedLayoutStore.write(tabs: [])
        state2.restorePinnedState(WorkspaceStore(fileURL: fx.storeURL).load().pinned)

        state2.reconcilePinnedLayoutAtLaunch(projects: [p])

        #expect(state2.pinnedRecords.isEmpty)
        // Honored as a MOVE: the tab landed in its origin project.
        #expect(state2.workspaces[p.id]?.tabs.map(\.id) == [tab.id])
    }

    @Test
    func launch_reconcile_absent_file_keeps_records_and_materializes_file() {
        let fx = makeFixture()
        let record = PinnedTabRecord(
            id: UUID(),
            declaration: LayoutTab(name: "mine", layout: .pane(LayoutPane())),
            originProjectID: nil
        )
        fx.state.pinnedRecords = [record]

        fx.state.reconcilePinnedLayoutAtLaunch(projects: [])

        #expect(fx.state.pinnedRecords.map(\.id) == [record.id])
        #expect(FileManager.default.fileExists(atPath: fx.state.pinnedLayoutStore.fileURL.path))
    }

    @Test
    func invalid_pinned_yaml_suspends_writes_and_preserves_the_file() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id) // creates a valid file

        // The user breaks the file mid-edit.
        let broken = "path: <pinned>\ntabs: [ not yaml {"
        try broken.write(to: fx.state.pinnedLayoutStore.fileURL, atomically: true, encoding: .utf8)

        // A membership change would normally rewrite — it must not clobber.
        fx.state.unpinTab(tab.id, projects: [p])

        #expect(fx.state.pinnedLayoutSuspended)
        let onDisk = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(onDisk == broken)
    }

    @Test
    func external_addition_is_absorbed_before_the_next_write() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let first = ws.tabs[0]
        let second = ws.createTab(projectPath: p.path)
        fx.state.pinTab(first.id, fromProject: p.id)

        // Hand-edit while running: append an entry. The existing entry is
        // matched back by content (no wire-level ids).
        try fx.state.pinnedLayoutStore.write(tabs: [
            fx.state.pinnedRecords[0].declaration,
            LayoutTab(name: "external", layout: .pane(LayoutPane(run: "htop"))),
        ])

        // Next membership change triggers a write, which absorbs first.
        fx.state.pinTab(second.id, fromProject: p.id)

        #expect(fx.state.pinnedRecords.count == 3)
        #expect(fx.state.pinnedRecords.contains { $0.declaration.name == "external" })
        // The absorbed entry survived the rewrite too.
        let text = try String(contentsOf: fx.state.pinnedLayoutStore.fileURL, encoding: .utf8)
        #expect(text.contains("external"))
    }

    // MARK: - Keyboard navigation

    @Test
    func nextTabInProject_cycles_pinned_records_and_restores_unloaded_ones() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let tab = try #require(fx.state.workspaces[p.id]?.activeTab)
        fx.state.pinTab(tab.id, fromProject: p.id)
        let unloadedID = UUID()
        fx.state.pinnedRecords.append(PinnedTabRecord(
            id: unloadedID,
            declaration: LayoutTab(layout: .pane(LayoutPane(cwd: "/tmp", run: "btop"))),
            originProjectID: nil
        ))

        fx.state.selectNextTab(projectID: PinnedTabs.projectID)

        // Landed on the unloaded record and restored it.
        #expect(fx.state.pinnedWorkspace?.activeTabID == unloadedID)
        #expect(fx.state.isPinnedTabLoaded(unloadedID))

        fx.state.selectPreviousTab(projectID: PinnedTabs.projectID)
        #expect(fx.state.pinnedWorkspace?.activeTabID == tab.id)
    }

    // MARK: - Global cycling

    @Test
    func selectGlobalTab_cycles_through_pinned_first() throws {
        let fx = makeFixture()
        let p = seedProject(fx.state)
        let ws = try #require(fx.state.workspaces[p.id])
        let pinnedTab = ws.tabs[0]
        let projectTab = ws.createTab(projectPath: p.path)
        fx.state.pinTab(pinnedTab.id, fromProject: p.id)
        fx.state.selectPinnedTab(pinnedTab.id)

        fx.state.selectGlobalTab(.next, projects: [p])

        #expect(fx.state.activeProjectID == p.id)
        #expect(fx.state.workspaces[p.id]?.activeTabID == projectTab.id)

        fx.state.selectGlobalTab(.next, projects: [p])
        #expect(fx.state.activeProjectID == pinnedID)
        #expect(fx.state.pinnedWorkspace?.activeTabID == pinnedTab.id)
    }
}
