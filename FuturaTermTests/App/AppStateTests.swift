import AppKit
import CoreGraphics
import Foundation
@testable import FuturaTerm
import os
import Testing

@MainActor
struct AppStateTests {
    // MARK: - Setup helpers

    /// Build an AppState with a temp-file workspace store and a temp-dir
    /// project-file store so tests don't touch the user's real App Support
    /// data or `~/.config/futuraterm/projects`.
    private func makeAppState(
        store: WorkspaceStore? = nil,
        projectFiles: ProjectFileStore? = nil
    ) -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-\(UUID().uuidString).json")
        return AppState(
            workspaceStore: store ?? WorkspaceStore(fileURL: tmp),
            projectFiles: projectFiles ?? makeProjectFileStore()
        )
    }

    /// Fresh central project-file store rooted in a unique tempdir.
    private func makeProjectFileStore() -> ProjectFileStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return ProjectFileStore(directoryURL: dir)
    }

    /// Create a project + workspace inside `state` and return the project.
    private func seedProject(_ state: AppState, name: String = "proj", path: String = "/tmp") -> Project {
        let p = Project(name: name, path: path, sortOrder: 0)
        state.selectProject(p)
        return p
    }

    /// A pid that `ProcessInspector.comm` can see, not 1 and not this test process.
    private func livePidForKillTests() -> pid_t {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        if let pid = NSWorkspace.shared.runningApplications.map(\.processIdentifier).first(where: { pid in
            pid > 1 && pid != selfPid && ProcessInspector.comm(pid: pid) != nil
        }) {
            return pid
        }
        Issue.record("no live pid available for killLocalListeners tests")
        return 0
    }

    private func listenerRow(
        id: String,
        pid: pid_t = 42,
        port: Int = 3000,
        command: String = "vite",
        displayURL: String? = nil,
        projectID: UUID? = nil,
        startDate: Date? = nil
    ) -> LocalListenerInventory.Row {
        LocalListenerInventory.Row(
            id: id,
            pid: pid,
            command: command,
            port: port,
            address: "127.0.0.1",
            displayURL: displayURL ?? "http://127.0.0.1:\(port)",
            cwd: "/tmp/app",
            argvSummary: "\(command)",
            projectName: nil,
            projectID: projectID,
            startDate: startDate
        )
    }

    /// Isolated `projects.json` so Open/New tests never touch the live store.
    private func makeProjectStore() -> ProjectStore {
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString).json")
        let groups = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-groups-\(UUID().uuidString).json")
        return ProjectStore(fileURL: projects, groupsFileURL: groups)
    }

    // MARK: - Splits

    @Test
    func splitPane_adds_pane_and_focuses_it() throws {
        let prior = Preferences.shared.startGrokInNewTabs
        defer { Preferences.shared.startGrokInNewTabs = prior }
        Preferences.shared.startGrokInNewTabs = true

        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.splitPane(direction: .horizontal, projectID: p.id)
        #expect(tab.splitRoot.allPanes().count == 2)
        #expect(tab.focusedPaneID != before)
        let newPane = try #require(tab.focusedPane)
        #expect(newPane.command == nil)
        #expect(tab.splitRoot.allPanes().allSatisfy { $0.command == nil })
    }

    @Test
    func splitPane_no_focused_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        tab.focusedPaneID = nil
        state.splitPane(direction: .horizontal, projectID: p.id)
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    @Test
    func adaptiveBackgroundColor_updatesOwnedPaneOnly() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.focusedPane)
        let color = CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)

        state.setAdaptiveBackgroundColor(color, paneID: pane.id, projectID: project.id)
        #expect(pane.adaptiveBackgroundColor == color)

        let otherProject = seedProject(state, name: "other", path: "/tmp/other")
        state.setAdaptiveBackgroundColor(nil, paneID: pane.id, projectID: otherProject.id)
        #expect(pane.adaptiveBackgroundColor == color)

        state.setAdaptiveBackgroundColor(nil, paneID: UUID(), projectID: project.id)
        #expect(pane.adaptiveBackgroundColor == color)

        state.setAdaptiveBackgroundColor(nil, paneID: pane.id, projectID: project.id)
        #expect(pane.adaptiveBackgroundColor == nil)
    }

    // MARK: - Close pane

    @Test
    func closePane_last_pane_closes_the_whole_tab() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let originalTab = try #require(ws.activeTab)
        let onlyPane = try #require(originalTab.focusedPaneID)
        // Add a second tab so closing the original doesn't leave us with zero.
        _ = ws.createTab(projectPath: "/tmp")
        let otherTab = try #require(ws.activeTabID)

        // Focus the original tab, then close its only pane.
        ws.selectTab(originalTab.id)
        state.closePane(onlyPane, projectID: p.id)

        #expect(ws.tabs.count == 1)
        #expect(ws.activeTabID == otherTab)
    }

    @Test
    func closePane_middle_pane_removes_from_tree() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        #expect(tab.splitRoot.allPanes().count == 2)
        let target = try #require(tab.focusedPaneID)
        state.closePane(target, projectID: p.id)
        #expect(tab.splitRoot.allPanes().count == 1)
        #expect(tab.focusedPaneID != target)
    }

    /// Integration-level regression: HV-close on the active tab via AppState.
    @Test
    func closePane_HV_close_regression() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)

        // Replace splitRoot with a known HV shape.
        let (tree, ids) = build(H(pane("l1"), V(pane("r1"), pane("r2"))))
        tab.splitRoot = tree
        tab.focusedPaneID = ids["l1"]

        try state.closePane(#require(ids["l1"]), projectID: p.id)

        #expect(render(tab.splitRoot, ids: ids) == "V(r1, r2)")
        let remaining = Set(tab.splitRoot.allPanes().map(\.id))
        #expect(try remaining == [#require(ids["r1"]), #require(ids["r2"])])
    }

    @Test
    func closePane_from_non_active_tab_still_works() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let originalTab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let targetInOriginal = try #require(originalTab.focusedPaneID)

        // Switch to a new tab, then close a pane on the (now non-active) original.
        _ = ws.createTab(projectPath: "/tmp")
        #expect(ws.activeTabID != originalTab.id)
        state.closePane(targetInOriginal, projectID: p.id)
        #expect(originalTab.splitRoot.allPanes().count == 1)
    }

    // MARK: - Move tab between projects

    @Test
    func moveTab_relocates_tab_and_activates_destination() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        // Give p1 a second tab so moving one away doesn't empty it.
        let moving = ws1.createTab(projectPath: "/tmp1")
        let staying = try #require(ws1.tabs.first?.id)

        state.moveTab(moving.id, from: p1.id, to: p2.id, destPath: p2.path)

        // Source lost the tab; destination gained it (object reused, surfaces intact).
        #expect(ws1.tabs.map(\.id) == [staying])
        let ws2 = try #require(state.workspaces[p2.id])
        #expect(ws2.tabs.contains { $0.id == moving.id })
        // Destination is now active with the moved tab selected.
        #expect(state.activeProjectID == p2.id)
        #expect(ws2.activeTabID == moving.id)
    }

    @Test
    func moveTab_leaves_source_workspace_empty_when_moving_its_only_tab() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        let only = try #require(ws1.tabs.first?.id)

        state.moveTab(only, from: p1.id, to: p2.id, destPath: p2.path)

        #expect(ws1.tabs.isEmpty)
        #expect(ws1.activeTabID == nil)
        #expect(state.workspaces[p2.id]?.tabs.contains { $0.id == only } == true)
    }

    @Test
    func moveTab_creates_destination_workspace_when_absent() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let ws1 = try #require(state.workspaces[p1.id])
        let tab = ws1.createTab(projectPath: "/tmp1")
        // A project that's never been opened — no workspace yet.
        let p2 = Project(name: "p2", path: "/tmp2", sortOrder: 1)
        #expect(state.workspaces[p2.id] == nil)

        state.moveTab(tab.id, from: p1.id, to: p2.id, destPath: p2.path)

        let ws2 = try #require(state.workspaces[p2.id])
        #expect(ws2.tabs.contains { $0.id == tab.id })
    }

    @Test
    func moveTab_same_project_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let before = ws.tabs.map(\.id)
        try state.moveTab(#require(before.first), from: p.id, to: p.id, destPath: p.path)
        #expect(ws.tabs.map(\.id) == before)
    }

    @Test
    func moveTab_unknown_tab_is_noop() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws2Before = try #require(state.workspaces[p2.id]).tabs.count
        state.moveTab(UUID(), from: p1.id, to: p2.id, destPath: p2.path)
        #expect(state.workspaces[p2.id]?.tabs.count == ws2Before)
    }

    // MARK: - Merge a tab into the workspace's active tab (#227)

    @Test
    func mergeTab_at_pane_target_splits_in_zone_direction() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let destTab = try #require(ws.activeTab)
        let destPane = try #require(destTab.splitRoot.allPanes().first?.id)
        let sourceTab = ws.createTab(projectPath: p.path)
        let sourcePane = try #require(sourceTab.splitRoot.allPanes().first?.id)
        ws.selectTab(destTab.id)

        state.mergeTab(sourceTab.id, from: p.id, at: .pane(destPane, .top), inProject: p.id)

        #expect(ws.tabs.map(\.id) == [destTab.id])
        // .top means the source lands first in a vertical split.
        #expect(destTab.splitRoot.allPanes().map(\.id) == [sourcePane, destPane])
        guard case let .split(branch) = destTab.splitRoot else {
            Issue.record("expected a split root")
            return
        }
        #expect(branch.direction == .vertical)
    }

    @Test
    func mergeTab_at_rootEdge_equalizes_to_thirds() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let destTab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let sourceTab = ws.createTab(projectPath: p.path)
        ws.selectTab(destTab.id)

        state.mergeTab(sourceTab.id, from: p.id, at: .rootEdge(.left), inProject: p.id)

        // Side-by-side-by-side: every column takes an even third.
        let frames = destTab.splitRoot.paneFrames()
        #expect(frames.count == 3)
        for frame in frames.values {
            #expect(abs(frame.width - 1.0 / 3.0) < 0.001)
        }
    }

    @Test
    func mergeTab_when_active_tab_is_source_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.mergeTab(tab.id, from: p.id, at: .rootEdge(.bottom), inProject: p.id)
        #expect(ws.tabs.count == 1)
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    // MARK: - Separate panes (#227)

    @Test
    func separateTabPanes_gives_each_pane_its_own_tab() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        state.splitPane(direction: .vertical, projectID: p.id)
        let panes = tab.splitRoot.allPanes().map(\.id)
        #expect(panes.count == 3)

        state.separateTabPanes(tab.id, projectID: p.id)

        // One tab per pane, inserted right after the source in tree order;
        // the source keeps the first pane and stays selected.
        #expect(ws.tabs.count == 3)
        #expect(ws.tabs.first?.id == tab.id)
        #expect(tab.splitRoot.allPanes().map(\.id) == [panes[0]])
        #expect(tab.focusedPaneID == panes[0])
        #expect(ws.tabs.map { $0.splitRoot.allPanes().map(\.id) } == panes.map { [$0] })
        #expect(ws.activeTabID == tab.id)
    }

    @Test
    func separateTabPanes_single_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.separateTabPanes(tab.id, projectID: p.id)
        #expect(ws.tabs.count == 1)
    }

    // MARK: - Separate one pane into its own tab (Separate Current Pane)

    @Test
    func separatePane_splits_the_pane_into_its_own_tab() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        let original = try #require(tab.focusedPaneID)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let dragged = try #require(tab.focusedPaneID)
        tab.zoomedPaneID = dragged

        state.separatePane(dragged, toProject: p.id, destPath: p.path)

        // The source tab keeps its remaining pane, exits the stale zoom, and
        // repairs focus; the dragged Pane object lives on in the new tab.
        #expect(tab.splitRoot.allPanes().map(\.id) == [original])
        #expect(tab.zoomedPaneID == nil)
        #expect(tab.focusedPaneID == original)
        #expect(ws.tabs.count == 2)
        let newTab = try #require(ws.tabs.last)
        #expect(newTab.splitRoot.allPanes().map(\.id) == [dragged])
        #expect(newTab.focusedPaneID == dragged)
        #expect(ws.activeTabID == newTab.id)
    }

    @Test
    func separatePane_at_index_lands_at_that_slot() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let dragged = try #require(tab.focusedPaneID)

        state.separatePane(dragged, toProject: p.id, destPath: p.path, at: 0)

        #expect(ws.tabs.count == 2)
        #expect(ws.tabs.first?.splitRoot.allPanes().map(\.id) == [dragged])
        #expect(ws.tabs.last?.id == tab.id)
    }

    @Test
    func separatePane_across_projects_rebinds_and_activates_destination() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        let ws2 = try #require(state.workspaces[p2.id])
        state.selectProject(p1)
        state.splitPane(direction: .horizontal, projectID: p1.id)
        let sourceTab = try #require(ws1.activeTab)
        let dragged = try #require(sourceTab.focusedPaneID)
        let ws2TabsBefore = ws2.tabs.count

        state.separatePane(dragged, toProject: p2.id, destPath: p2.path)

        #expect(sourceTab.splitRoot.allPanes().count == 1)
        #expect(ws2.tabs.count == ws2TabsBefore + 1)
        let newTab = try #require(ws2.tabs.last)
        #expect(newTab.splitRoot.allPanes().map(\.id) == [dragged])
        // Routing identity follows the pane, mirroring moveTab's rebind.
        #expect(newTab.splitRoot.allPanes().allSatisfy { $0.projectID == p2.id })
        #expect(state.activeProjectID == p2.id)
        #expect(ws2.activeTabID == newTab.id)
    }

    @Test
    func separatePane_only_pane_of_its_tab_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        let onlyPane = try #require(tab.focusedPaneID)
        state.separatePane(onlyPane, toProject: p.id, destPath: p.path)
        #expect(ws.tabs.count == 1)
        #expect(tab.splitRoot.allPanes().map(\.id) == [onlyPane])
    }

    @Test
    func separatePane_unknown_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        state.separatePane(UUID(), toProject: p.id, destPath: p.path)
        #expect(ws.tabs.count == 1)
    }

    // MARK: - Project-scoped tab navigation

    @Test
    func selectNextTab_wraps_within_the_project() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let other = seedProject(state, name: "other", path: "/tmp/other")
        let ws = try #require(state.workspaces[p.id])
        let first = try #require(ws.activeTabID)
        let second = ws.createTab(projectPath: p.path).id
        // Seed a tab in the sibling project so a leak across projects would show.
        _ = try #require(state.workspaces[other.id]?.activeTabID)
        state.activeProjectID = p.id
        ws.selectTab(first)

        state.selectNextTab(projectID: p.id)
        #expect(ws.activeTabID == second)
        // At the last tab it wraps to the first rather than crossing over.
        state.selectNextTab(projectID: p.id)
        #expect(ws.activeTabID == first)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func selectPreviousTab_wraps_within_the_project() throws {
        let state = makeAppState()
        let p = seedProject(state)
        _ = seedProject(state, name: "other", path: "/tmp/other")
        let ws = try #require(state.workspaces[p.id])
        let first = try #require(ws.activeTabID)
        let second = ws.createTab(projectPath: p.path).id
        state.activeProjectID = p.id
        ws.selectTab(first)

        // At the first tab it wraps to the last rather than crossing over.
        state.selectPreviousTab(projectID: p.id)
        #expect(ws.activeTabID == second)
        state.selectPreviousTab(projectID: p.id)
        #expect(ws.activeTabID == first)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func selectNextTab_single_tab_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let only = try #require(ws.activeTabID)
        state.selectNextTab(projectID: p.id)
        state.selectPreviousTab(projectID: p.id)
        #expect(ws.activeTabID == only)
    }

    // MARK: - Focus navigation

    @Test
    func focusPaneInDirection_right_in_horizontal_split() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), pane("b")))
        tab.splitRoot = tree
        tab.focusedPaneID = ids["a"]
        state.focusPaneInDirection(.right, projectID: p.id)
        #expect(tab.focusedPaneID == ids["b"])
    }

    @Test
    func focusPaneInDirection_no_neighbor_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.focusPaneInDirection(.right, projectID: p.id)
        #expect(tab.focusedPaneID == before)
    }

    @Test
    func cyclePane_forward_advances_in_tree_order() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), V(pane("b"), pane("c"))))
        tab.splitRoot = tree
        tab.focusedPaneID = ids["a"]
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == ids["b"])
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == ids["c"])
    }

    @Test
    func cyclePane_forward_wraps_at_end() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), pane("b")))
        tab.splitRoot = tree
        tab.focusedPaneID = ids["b"]
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == ids["a"])
    }

    @Test
    func cyclePane_backward_wraps_at_start() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let (tree, ids) = build(H(pane("a"), pane("b")))
        tab.splitRoot = tree
        tab.focusedPaneID = ids["a"]
        state.cyclePane(forward: false, projectID: p.id)
        #expect(tab.focusedPaneID == ids["b"])
    }

    @Test
    func cyclePane_single_pane_is_noop() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let before = tab.focusedPaneID
        state.cyclePane(forward: true, projectID: p.id)
        #expect(tab.focusedPaneID == before)
    }

    // MARK: - Project lifecycle

    @Test
    func removeProject_drops_workspace_and_clears_active_when_matching() {
        let state = makeAppState()
        let p = seedProject(state)
        #expect(state.activeProjectID == p.id)
        state.removeProject(p.id)
        #expect(state.workspaces[p.id] == nil)
        #expect(state.activeProjectID == nil)
    }

    @Test
    func removeProject_leaves_active_alone_when_not_matching() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        // p2 is active; remove p1.
        state.removeProject(p1.id)
        #expect(state.activeProjectID == p2.id)
    }

    @Test
    func two_projects_for_the_same_directory_get_independent_workspaces_and_sessions() throws {
        // Removing the one-project-per-directory constraint: distinct projects
        // may share a path yet keep wholly separate workspaces (keyed on
        // Project.id) and non-colliding zmx sessions (per-pane hex entropy).
        let state = makeAppState()
        let a = seedProject(state, name: "a", path: "/tmp/shared")
        let b = seedProject(state, name: "b", path: "/tmp/shared")

        #expect(a.id != b.id)
        let wsA = try #require(state.workspaces[a.id])
        let wsB = try #require(state.workspaces[b.id])
        #expect(wsA !== wsB)

        // Session names differ despite the shared path: the slug matches but
        // each pane's hex suffix comes from its own UUID.
        let nameA = try #require(wsA.activeTab?.splitRoot.allPanes().first?.sessionName)
        let nameB = try #require(wsB.activeTab?.splitRoot.allPanes().first?.sessionName)
        #expect(nameA != nameB)
    }

    // MARK: - Bulk removal (sidebar multi-select)

    @Test
    func removeProjects_drops_every_listed_workspace() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let p3 = seedProject(state, name: "p3", path: "/tmp3")

        state.removeProjects([p1.id, p3.id])

        #expect(state.workspaces[p1.id] == nil)
        #expect(state.workspaces[p3.id] == nil)
        #expect(state.workspaces[p2.id] != nil)
    }

    @Test
    func removeProjects_empty_list_is_noop() {
        let state = makeAppState()
        let p = seedProject(state)
        state.removeProjects([])
        #expect(state.workspaces[p.id] != nil)
        #expect(state.activeProjectID == p.id)
    }

    @Test
    func closeTabs_closes_each_tab_across_projects() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let ws1 = try #require(state.workspaces[p1.id])
        let ws2 = try #require(state.workspaces[p2.id])
        // Two tabs in each so closing one doesn't empty the workspace.
        let close1 = ws1.createTab(projectPath: "/tmp1")
        let keep1 = try #require(ws1.tabs.first?.id)
        let close2 = ws2.createTab(projectPath: "/tmp2")
        let keep2 = try #require(ws2.tabs.first?.id)

        state.closeTabs([
            (tabID: close1.id, projectID: p1.id),
            (tabID: close2.id, projectID: p2.id),
        ])

        #expect(ws1.tabs.map(\.id) == [keep1])
        #expect(ws2.tabs.map(\.id) == [keep2])
    }

    @Test
    func requestRemoveSelection_runs_removal_immediately_when_no_pane_busy() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        // No pane ever gets an NSView in tests, so nothing is "busy" — the
        // removal must run inline rather than staging a confirmation.
        var ran = false
        state.requestRemoveSelection(projectIDs: [p1.id, p2.id], tabs: []) { ran = true }

        #expect(ran)
        #expect(state.pendingBulkRemove == nil)
    }

    @Test
    func pendingBulkRemove_confirm_and_cancel() {
        let state = makeAppState()

        // Stage manually (busy detection needs a live surface).
        var ran = false
        state.pendingBulkRemove = AppState.PendingBulkRemove { ran = true }
        state.cancelPendingBulkRemove()
        #expect(state.pendingBulkRemove == nil)
        #expect(!ran)

        state.pendingBulkRemove = AppState.PendingBulkRemove { ran = true }
        state.confirmPendingBulkRemove()
        #expect(state.pendingBulkRemove == nil)
        #expect(ran)
    }

    @Test
    func selectTab_persists_cleared_completion_indicator() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceStore(fileURL: tmp)
        let state = makeAppState(store: store)
        let project = seedProject(state)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        pane.executionState = .done
        state.saveWorkspaces()

        state.selectTab(tab.id, projectID: project.id)

        let restored = WorkspaceSerializer.restore(from: store.load().workspaces, validIDs: [project.id])
        #expect(restored.first?.tabs.first?.executionState == .idle)
    }

    @Test
    func selectProject_persists_cleared_active_tab_indicator() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceStore(fileURL: tmp)
        let state = makeAppState(store: store)
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        _ = seedProject(state, name: "p2", path: "/tmp2")
        let tab = try #require(state.workspaces[p1.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        pane.executionState = .done
        state.saveWorkspaces()

        state.selectProject(p1)

        let restored = WorkspaceSerializer.restore(from: store.load().workspaces, validIDs: [p1.id])
        #expect(restored.first?.tabs.first?.executionState == .idle)
    }

    // MARK: - New tabs (POR-335)

    @Test
    func createTab_pref_on_starts_grok() throws {
        let prior = Preferences.shared.startGrokInNewTabs
        defer { Preferences.shared.startGrokInNewTabs = prior }
        Preferences.shared.startGrokInNewTabs = true

        let state = makeAppState()
        let p = seedProject(state)
        let tabID = try #require(state.createTab(projectID: p.id, projectPath: p.path))
        let ws = try #require(state.workspaces[p.id])
        #expect(ws.tabs.count == 2)
        #expect(ws.tabs[0].id != tabID)
        #expect(ws.tabs[0].splitRoot.allPanes().first?.command == nil)
        let newPane = try #require(ws.tabs.last?.splitRoot.allPanes().first)
        #expect(ws.tabs.last?.id == tabID)
        #expect(newPane.command == "grok")
        #expect(newPane.projectPath == p.path)
    }

    @Test
    func createTab_pref_off_leaves_command_nil() throws {
        let prior = Preferences.shared.startGrokInNewTabs
        defer { Preferences.shared.startGrokInNewTabs = prior }
        Preferences.shared.startGrokInNewTabs = false

        let state = makeAppState()
        let p = seedProject(state)
        let tabID = try #require(state.createTab(projectID: p.id, projectPath: p.path))
        let ws = try #require(state.workspaces[p.id])
        #expect(ws.tabs.count == 2)
        #expect(ws.tabs.last?.id == tabID)
        #expect(ws.tabs.last?.splitRoot.allPanes().first?.command == nil)
    }

    @Test
    func createTab_explicit_command_wins() throws {
        let prior = Preferences.shared.startGrokInNewTabs
        defer { Preferences.shared.startGrokInNewTabs = prior }
        Preferences.shared.startGrokInNewTabs = true

        let state = makeAppState()
        let p = seedProject(state)
        let tabID = try #require(state.createTab(projectID: p.id, projectPath: p.path, command: "btop"))
        let ws = try #require(state.workspaces[p.id])
        #expect(ws.tabs.count == 2)
        #expect(ws.tabs.last?.id == tabID)
        #expect(ws.tabs.last?.splitRoot.allPanes().first?.command == "btop")
    }

    @Test
    func createTab_empty_explicit_falls_through_to_grok() throws {
        let prior = Preferences.shared.startGrokInNewTabs
        defer { Preferences.shared.startGrokInNewTabs = prior }
        Preferences.shared.startGrokInNewTabs = true

        let state = makeAppState()
        let p = seedProject(state)
        let tabID = try #require(state.createTab(projectID: p.id, projectPath: p.path, command: ""))
        let ws = try #require(state.workspaces[p.id])
        #expect(ws.tabs.count == 2)
        #expect(ws.tabs.last?.id == tabID)
        #expect(ws.tabs.last?.splitRoot.allPanes().first?.command == "grok")
    }

    @Test
    func createTab_pinned_workspace_does_not_start_grok() throws {
        let prior = Preferences.shared.startGrokInNewTabs
        defer { Preferences.shared.startGrokInNewTabs = prior }
        Preferences.shared.startGrokInNewTabs = true

        let state = makeAppState()
        state.selectPinnedProject()
        let tabID = try #require(
            state.createTab(projectID: PinnedTabs.projectID, projectPath: PinnedTabs.fallbackRoot)
        )
        let ws = try #require(state.workspaces[PinnedTabs.projectID])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs.last?.id == tabID)
        #expect(ws.tabs.last?.splitRoot.allPanes().first?.command == nil)
    }

    @Test
    func resolvedNewTabCommand_matches_createTab_policy() {
        let prior = Preferences.shared.startGrokInNewTabs
        defer { Preferences.shared.startGrokInNewTabs = prior }
        let state = makeAppState()
        let projectID = UUID()

        Preferences.shared.startGrokInNewTabs = true
        #expect(state.resolvedNewTabCommand(explicit: nil, projectID: projectID) == "grok")
        #expect(state.resolvedNewTabCommand(explicit: "", projectID: projectID) == "grok")
        Preferences.shared.startGrokInNewTabs = false
        #expect(state.resolvedNewTabCommand(explicit: nil, projectID: projectID) == nil)
        #expect(state.resolvedNewTabCommand(explicit: "", projectID: projectID) == nil)
        #expect(state.resolvedNewTabCommand(explicit: "btop", projectID: projectID) == "btop")
        Preferences.shared.startGrokInNewTabs = true
        #expect(state.resolvedNewTabCommand(explicit: nil, projectID: PinnedTabs.projectID) == nil)
        #expect(state.resolvedNewTabCommand(explicit: "", projectID: PinnedTabs.projectID) == nil)
        #expect(state.resolvedNewTabCommand(explicit: "btop", projectID: PinnedTabs.projectID) == "btop")
    }

    // MARK: - Unload project

    @Test
    func unloadProject_keeps_tab_structure_with_fresh_panes() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        state.splitPane(direction: .horizontal, projectID: p.id)
        ws.createTab(projectPath: "/tmp")
        ws.tabs[1].customTitle = "build"
        let beforePaneIDs = Set(ws.tabs.flatMap { $0.splitRoot.allPanes().map(\.id) })
        let beforeTabIDs = ws.tabs.map(\.id)

        state.unloadProject(p.id)

        let after = try #require(state.workspaces[p.id])
        #expect(after.tabs.map(\.id) == beforeTabIDs)
        #expect(after.tabs[0].splitRoot.allPanes().count == 2)
        #expect(after.tabs[1].customTitle == "build")
        // Panes are rebuilt fresh (no surfaces), like a launch restore.
        let afterPaneIDs = Set(after.tabs.flatMap { $0.splitRoot.allPanes().map(\.id) })
        #expect(afterPaneIDs.isDisjoint(with: beforePaneIDs))
    }

    @Test
    func unloadProject_destroys_pane_views() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        _ = pane.ensureNSView()
        #expect(state.isProjectLoaded(p.id))

        state.unloadProject(p.id)

        #expect(pane.nsView == nil)
        #expect(!state.isProjectLoaded(p.id))
    }

    @Test
    func unloadProject_active_project_is_deselected_but_kept() {
        let state = makeAppState()
        let p = seedProject(state)
        #expect(state.activeProjectID == p.id)
        state.unloadProject(p.id)
        #expect(state.activeProjectID == nil)
        #expect(state.workspaces[p.id] != nil)
    }

    @Test
    func unloadProject_other_project_keeps_active() {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        state.unloadProject(p1.id)
        #expect(state.activeProjectID == p2.id)
        #expect(state.workspaces[p1.id] != nil)
    }

    @Test
    func unloadProject_unknown_project_is_noop() {
        let state = makeAppState()
        let p = seedProject(state)
        state.unloadProject(UUID())
        #expect(state.activeProjectID == p.id)
        #expect(state.workspaces.count == 1)
    }

    @Test
    func unloadProject_marks_the_project_unloaded() {
        let state = makeAppState()
        let p = seedProject(state)
        #expect(!state.isProjectUnloaded(p.id))
        state.unloadProject(p.id)
        // The sidebar reads this to dim the project's tab rows, the same way
        // a closed pinned tab's row is dimmed.
        #expect(state.isProjectUnloaded(p.id))
    }

    @Test
    func selecting_an_unloaded_project_clears_the_mark() {
        let state = makeAppState()
        let p = seedProject(state)
        state.unloadProject(p.id)
        state.selectProject(p)
        #expect(!state.isProjectUnloaded(p.id))
    }

    @Test
    func becoming_active_clears_the_mark_without_selectProject() {
        let state = makeAppState()
        let p = seedProject(state, name: "p1", path: "/tmp1")
        _ = seedProject(state, name: "p2", path: "/tmp2")
        state.unloadProject(p.id)
        // Every load path makes the project active — a cross-project tab
        // move or a global tab cycle sets the id directly.
        state.activeProjectID = p.id
        #expect(!state.isProjectUnloaded(p.id))
    }

    @Test
    func removing_an_unloaded_project_forgets_the_mark() {
        let state = makeAppState()
        let p = seedProject(state)
        state.unloadProject(p.id)
        state.removeProject(p.id)
        #expect(!state.isProjectUnloaded(p.id))
    }

    @Test
    func isProjectLoaded_false_without_views_or_workspace() {
        let state = makeAppState()
        #expect(!state.isProjectLoaded(UUID()))
        let p = seedProject(state)
        // Workspace exists but no pane has a view yet (nothing ever rendered).
        #expect(!state.isProjectLoaded(p.id))
    }

    // MARK: - Rename state

    @Test
    func renamingTabID_defaults_to_nil() {
        let state = makeAppState()
        #expect(state.renamingTabID == nil)
    }

    @Test
    func renamingTabID_can_be_set_and_cleared() {
        let state = makeAppState()
        let id = UUID()
        state.renamingTabID = id
        #expect(state.renamingTabID == id)
        state.renamingTabID = nil
        #expect(state.renamingTabID == nil)
    }

    @Test
    func renameTabContaining_targets_the_panes_tab() async throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)
        state.sidebarVisible = false

        state.renameTab(containing: paneID, projectID: p.id)

        #expect(state.sidebarVisible)
        // The rename target lands a runloop tick later (the sidebar row's
        // TextField must exist before it's asked to edit) — poll with sleeps.
        for _ in 0 ..< 100 where state.renamingTabID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(state.renamingTabID == tab.id)
    }

    @Test
    func renameTabContaining_unknown_pane_is_noop() {
        let state = makeAppState()
        let p = seedProject(state)
        state.sidebarVisible = false
        state.renameTab(containing: UUID(), projectID: p.id)
        #expect(!state.sidebarVisible)
    }

    @Test
    func setTabTitleContaining_sets_and_clears_customTitle() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let paneID = try #require(tab.splitRoot.allPanes().first?.id)

        state.setTabTitle(containing: paneID, projectID: p.id, title: "deploy")
        #expect(tab.customTitle == "deploy")

        // Empty/nil restores the automatic title, same contract as the
        // ghostty keybind.
        state.setTabTitle(containing: paneID, projectID: p.id, title: nil)
        #expect(tab.customTitle == nil)
    }

    @Test
    func renamingProjectID_defaults_to_nil() {
        let state = makeAppState()
        #expect(state.renamingProjectID == nil)
        #expect(state.renamingFolderID == nil)
    }

    @Test
    func renamingProjectID_can_be_set_and_cleared() {
        let state = makeAppState()
        let id = UUID()
        state.renamingProjectID = id
        #expect(state.renamingProjectID == id)
        state.renamingProjectID = nil
        #expect(state.renamingProjectID == nil)
    }

    @Test
    func postPaletteAction_defaults_to_nil() {
        let state = makeAppState()
        #expect(state.postPaletteAction == nil)
    }

    @Test
    func postPaletteAction_is_invoked_and_consumed() {
        let state = makeAppState()
        var invoked = false
        state.postPaletteAction = { invoked = true }
        #expect(state.postPaletteAction != nil)
        state.postPaletteAction?()
        state.postPaletteAction = nil
        #expect(invoked)
        #expect(state.postPaletteAction == nil)
    }

    // MARK: - requestClosePane / pendingClosePane

    @Test
    func requestClosePane_without_running_process_closes_immediately() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let target = try #require(tab.focusedPaneID)
        // No GhosttyTerminalNSView is ever created in tests, so needsConfirmQuit is false.
        state.requestClosePane(target, projectID: p.id)
        #expect(state.pendingClosePane == nil)
        #expect(tab.splitRoot.allPanes().count == 1)
    }

    // MARK: - applyLayout

    /// Create a temp project directory and seed a workspace rooted there.
    private func seedProjectWithDir(_ state: AppState) -> (project: Project, root: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-layout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Project(name: "proj", path: dir.path, sortOrder: 0)
        state.selectProject(p)
        return (p, dir.path)
    }

    /// Write a raw central project file into `store`'s directory.
    private func writeProjectFile(_ yaml: String, in store: ProjectFileStore, filename: String = "test.yaml") {
        try? FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try? yaml.write(to: store.directoryURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    @Test
    func selecting_project_with_matching_project_file_auto_applies_on_first_open() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-autoapply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A central file declaring this path exists *before* first open.
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, in: files)

        let project = Project(name: "auto", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // Workspace built from the file (one tab, two panes), not the default
        // single-pane workspace. Non-destructive on first open → no prompt.
        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].customTitle == "Dev")
        #expect(ws.tabs[0].splitRoot.allPanes().count == 2)
        #expect(state.pendingLayoutApply == nil)
        #expect(state.pendingLayoutError == nil)
    }

    @Test
    func first_open_without_a_project_file_uses_the_default_workspace() throws {
        // No central file declares this path, so first open is a plain
        // single-pane workspace — nothing to seed it from now that the
        // in-repo `.futuraterm/layout.yaml` path is gone.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-nofile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "No File", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        #expect(state.pendingLayoutError == nil)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
        // Nothing is written on open — files appear only on explicit Save Layout.
        #expect(files.find(forProjectPath: dir.path) == nil)
    }

    @Test
    func first_open_with_invalid_project_file_surfaces_error_and_uses_default_workspace() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Header identifies the file; tabs fail the full decode.
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - split: { direction: horizontal, first: {} }
        """, in: files)

        let project = Project(name: "broken", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        #expect(state.pendingLayoutError?.verb == "apply")
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
    }

    @Test
    func apply_layout_without_a_project_file_surfaces_an_error() throws {
        // An already-open project with no central declaration: Apply Layout has
        // nothing to read and says so, rather than silently doing nothing.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-applynofile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "Existing", path: dir.path, sortOrder: 0)
        state.selectProject(project)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)

        state.applyLayoutPresentingError(project)

        #expect(state.pendingLayoutError?.verb == "apply")
        #expect(files.find(forProjectPath: dir.path) == nil)
        // The live workspace is untouched by a failed apply.
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
    }

    // MARK: - Action toasts

    @Test
    func save_layout_toasts_with_the_full_path_it_wrote() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, _) = seedProjectWithDir(state) // name "proj" → proj.yaml

        state.saveLayoutPresentingError(project)

        #expect(state.pendingLayoutError == nil)
        #expect(state.activeToast?.title == "Layout saved")
        // The full path, not just the filename: the projects directory isn't
        // somewhere the user necessarily has in mind, so the subtitle has to
        // say where to go look — while still naming *which* file a save with
        // several same-path candidates landed in.
        let subtitle = try #require(state.activeToast?.subtitle)
        #expect(subtitle.hasSuffix("proj.yaml"))
        #expect(subtitle.contains("/"))
        #expect(subtitle == ProjectPath.homeContracted(files.directoryURL.appendingPathComponent("proj.yaml").path))
    }

    @Test
    func save_layout_toast_contracts_the_home_prefix() {
        // A path under home renders as `~/…` — readable, and it keeps the
        // username out of screenshots. `homeContracted` is the same helper the
        // written file's own `path:` uses, so the two can't drift.
        let home = ProjectPath.currentHome
        #expect(ProjectPath.homeContracted("\(home)/.config/futuraterm/projects/a.yaml")
            == "~/.config/futuraterm/projects/a.yaml")
        // Outside home, it passes through rather than mangling the path.
        #expect(ProjectPath.homeContracted("/etc/futuraterm/a.yaml") == "/etc/futuraterm/a.yaml")
    }

    @Test
    func save_layout_conflict_raises_a_dialog_instead_of_a_toast() {
        // A stray file declaring the same path makes the save a *notice*, not a
        // clean success. Toasting "Layout saved" alongside would undercut the
        // dialog that explains what's wrong.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, root) = seedProjectWithDir(state)
        // Bare `path:` with no `name:` — files no project's slug owns, which is
        // what makes them strays rather than a sibling's legitimate file. Two,
        // mirroring `save_layout_lists_ignored_duplicates_when_the_save_wins`:
        // the save claims one and reports the rest.
        writeProjectFile("path: \(root)", in: files, filename: "aaa.yaml")
        writeProjectFile("path: \(root)", in: files, filename: "zzz.yaml")

        state.saveLayoutPresentingError(project)

        #expect(state.pendingLayoutError != nil)
        #expect(state.activeToast == nil)
    }

    @Test
    func apply_layout_toasts_only_when_user_invoked() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-toastapply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeProjectFile("path: \(dir.path)\ntabs:\n  - name: \"Dev\"\n", in: files)
        let project = Project(name: "toast", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // The first-open seed fires unbidden — it must stay silent.
        #expect(state.activeToast == nil)

        state.applyLayoutPresentingError(project, confirming: true)

        #expect(state.pendingLayoutError == nil)
        #expect(state.activeToast?.title == "Layout applied")
    }

    /// Both scenes in `FuturaTermApp` bind alerts to this one pending value, so a
    /// staged dialog has to say which window asked for it — an ungated binding
    /// opens the settings window purely to stack a duplicate dialog on the one
    /// the user is answering. The default must stay the main window: everything
    /// but the settings pane (palette, menu, sidebar, CLI) relies on it.
    @Test
    func staged_destructive_apply_records_the_window_that_asked_for_it() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-applyhost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        writeProjectFile("path: \(dir.path)\ntabs:\n  - name: \"Dev\"\n", in: files)
        let project = Project(name: "applyhost", path: dir.path, sortOrder: 0)
        state.selectProject(project)
        // A second live tab the one-tab declaration doesn't mention: applying
        // would close it, which is what stages the confirmation.
        state.createTab(projectID: project.id, projectPath: dir.path)

        state.applyLayoutPresentingError(project, confirming: true)
        #expect(state.pendingLayoutApply?.host == .mainWindow)

        state.cancelPendingLayoutApply()

        state.applyLayoutPresentingError(project, confirming: true, host: .settings)
        #expect(state.pendingLayoutApply?.host == .settings)
    }

    /// Same gate for the notice alerts: a Settings-invoked failure must not
    /// surface behind the main window (or in both).
    @Test
    func layout_error_records_the_window_that_asked_for_it() {
        let state = makeAppState(projectFiles: makeProjectFileStore())
        let (project, _) = seedProjectWithDir(state)

        state.applyLayoutPresentingError(project, confirming: true)
        #expect(state.pendingLayoutError?.host == .mainWindow)

        state.pendingLayoutError = nil

        state.applyLayoutPresentingError(project, confirming: true, host: .settings)
        #expect(state.pendingLayoutError?.host == .settings)
    }

    @Test
    func apply_layout_failure_raises_a_dialog_instead_of_a_toast() {
        // No file declares this project's path — the command surfaces the
        // error, and a success toast would flatly contradict it.
        let state = makeAppState(projectFiles: makeProjectFileStore())
        let (project, _) = seedProjectWithDir(state)

        state.applyLayoutPresentingError(project, confirming: true)

        #expect(state.pendingLayoutError != nil)
        #expect(state.activeToast == nil)
    }

    @Test
    func dismissing_a_superseded_toast_leaves_the_newer_one_up() {
        // The auto-dismiss task is keyed by toast id. A stale one firing after
        // a second toast replaced the first must not cut the new one short.
        let state = makeAppState()
        state.presentToast("First")
        let first = try? #require(state.activeToast?.id)
        state.presentToast("Second")

        if let first {
            state.dismissToast(first)
        }

        #expect(state.activeToast?.title == "Second")
    }

    @Test
    func dismissing_the_current_toast_clears_it() {
        let state = makeAppState()
        state.presentToast("Only")
        let id = state.activeToast?.id

        if let id {
            state.dismissToast(id)
        }

        #expect(state.activeToast == nil)
    }

    @Test
    func a_subtitled_toast_stays_up_longer() {
        // Two lines need more reading time than one.
        #expect(Toast(title: "Bare").duration < Toast(title: "Detailed", subtitle: "more").duration)
    }

    // MARK: - saveLayout duplicate conflicts

    @Test
    func save_layout_does_not_flag_a_sibling_projects_file() {
        // A distinct-name sibling on the same directory owns its own file.
        // Saving this project must neither report that file as a stray nor
        // realign-delete it.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, root) = seedProjectWithDir(state) // name "proj" → proj.yaml
        let sibling = Project(name: "other", path: root, sortOrder: 1)
        writeProjectFile("name: other\npath: \(root)", in: files, filename: "other.yaml")

        state.saveLayoutPresentingError(project, siblingProjects: [project, sibling])

        #expect(state.pendingLayoutError == nil)
        #expect(files.find(forProjectPath: root, preferredSlug: "other")?.url.lastPathComponent == "other.yaml")
        #expect(files.find(forProjectPath: root, preferredSlug: "proj")?.url.lastPathComponent == "proj.yaml")
    }

    @Test
    func save_layout_lists_ignored_duplicates_when_the_save_wins() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (project, root) = seedProjectWithDir(state)
        // "proj.yaml" (the save target) sorts before the surviving duplicate.
        writeProjectFile("path: \(root)", in: files, filename: "aaa.yaml")
        writeProjectFile("path: \(root)", in: files, filename: "zzz.yaml")

        state.saveLayoutPresentingError(project)

        let notice = try #require(state.pendingLayoutError)
        #expect(notice.title == "Layout saved with a conflict")
        #expect(notice.message.contains("zzz.yaml"))
        #expect(notice.message.contains("ignored"))
    }

    @Test
    func save_layout_stays_silent_without_duplicates() {
        let state = makeAppState()
        let (project, _) = seedProjectWithDir(state)
        state.saveLayoutPresentingError(project)
        #expect(state.pendingLayoutError == nil)
    }

    @Test
    func save_layout_warns_when_a_same_named_project_shares_the_directory() throws {
        // Two projects for one directory with the same name → same filename
        // slug → the same layout file. The save silently overwrote the other's
        // layout, so it must warn.
        let state = makeAppState()
        let (project, root) = seedProjectWithDir(state) // name "proj"
        let sibling = Project(name: "proj", path: root, sortOrder: 1)

        state.saveLayoutPresentingError(project, siblingProjects: [project, sibling])

        let notice = try #require(state.pendingLayoutError)
        #expect(notice.title == "Layout file shared with another project")
        #expect(notice.message.contains("proj"))
    }

    @Test
    func save_layout_stays_silent_when_same_dir_projects_have_distinct_names() {
        // Same directory but different names → distinct slug files
        // (`proj.yaml` / `other.yaml`), so there's no shared-file overwrite.
        let state = makeAppState()
        let (project, root) = seedProjectWithDir(state) // name "proj"
        let sibling = Project(name: "other", path: root, sortOrder: 1)

        state.saveLayoutPresentingError(project, siblingProjects: [project, sibling])

        #expect(state.pendingLayoutError == nil)
    }

    @Test
    func each_same_directory_project_saves_and_loads_its_own_layout() throws {
        // The core guarantee of per-project layout identity: two distinct-name
        // projects on one directory each save to and load from their own file —
        // saving one never clobbers the other's, and neither resolves the
        // other's on load (path alone can't tell them apart; the slug does).
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let alpha = Project(name: "alpha", path: dir.path, sortOrder: 0)
        let bravo = Project(name: "bravo", path: dir.path, sortOrder: 1)
        state.selectProject(alpha)
        state.selectProject(bravo)
        let siblings = [alpha, bravo]

        state.saveLayoutPresentingError(alpha, siblingProjects: siblings)
        state.saveLayoutPresentingError(bravo, siblingProjects: siblings)

        #expect(state.pendingLayoutError == nil)
        // Both files coexist — saving bravo didn't realign-delete alpha's.
        #expect(files.find(forProjectPath: dir.path, preferredSlug: "alpha")?.url.lastPathComponent == "alpha.yaml")
        #expect(files.find(forProjectPath: dir.path, preferredSlug: "bravo")?.url.lastPathComponent == "bravo.yaml")
        // Each resolves the file it wrote, identified by the stored name.
        #expect(try files.loadFull(forProjectPath: dir.path, preferredSlug: "alpha")?.name == "alpha")
        #expect(try files.loadFull(forProjectPath: dir.path, preferredSlug: "bravo")?.name == "bravo")
    }

    @Test
    func selecting_project_without_layout_file_uses_default_workspace() {
        let state = makeAppState()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-nolayout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "plain", path: dir.path, sortOrder: 0)
        state.selectProject(project)

        // No layout file → default single-pane workspace.
        #expect(state.workspaces[project.id]?.tabs.count == 1)
        #expect(state.workspaces[project.id]?.tabs[0].splitRoot.allPanes().count == 1)
    }

    @Test
    func selectNextProject_follows_sidebar_folder_order() {
        let state = makeAppState()
        let ungrouped = Project(name: "ungrouped", path: "/tmp/u", sortOrder: 0)
        let a = Project(name: "a", path: "/tmp/a", sortOrder: 1)
        let b = Project(name: "b", path: "/tmp/b", sortOrder: 2)
        state.selectProject(ungrouped)
        let visual = [a, b, ungrouped]
        state.selectNextProject(projects: visual)
        #expect(state.activeProjectID == a.id)
        state.selectNextProject(projects: visual)
        #expect(state.activeProjectID == b.id)
        state.selectNextProject(projects: visual)
        #expect(state.activeProjectID == ungrouped.id)
        state.selectPreviousProject(projects: visual)
        #expect(state.activeProjectID == b.id)
    }

    @Test
    func reopen_restores_snapshot_silently_and_ignores_project_file() throws {
        // Reopen is always silent: a restored session snapshot wins (a
        // project's panes must reattach their live zmx sessions, and its live
        // layout is remembered), and the declared file is NOT applied and NOT
        // prompted for — even when it differs. The file only seeds a genuine
        // first open (no snapshot), covered by the next test.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-reopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(name: "winner", path: dir.path, sortOrder: 0)

        // Pre-seed a saved snapshot for the project: a single-pane workspace.
        let storeURL = dir.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(fileURL: storeURL)
        let snapshotWS = Workspace(projectID: project.id, projectPath: dir.path)
        store.save(WorkspaceSerializer.snapshot([project.id: snapshotWS]))

        // And a central file declaring a different (two-pane) split.
        let files = makeProjectFileStore()
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, in: files)

        let priorActive = Preferences.shared.activeProjectID
        Preferences.shared.activeProjectID = project.id
        defer { Preferences.shared.activeProjectID = priorActive }

        let state = makeAppState(store: store, projectFiles: files)
        state.restoreSelection(projects: [project])

        // Restored snapshot wins: one pane, file NOT applied, NO prompt.
        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs[0].splitRoot.allPanes().count == 1)
        #expect(ws.tabs[0].customTitle != "Dev")
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func project_file_auto_applies_on_genuine_first_open_without_snapshot() throws {
        // No snapshot at all → the declared file still seeds the workspace on
        // first open (pure-spawn, no prompt). The only auto-apply path left.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-firstopen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(name: "fresh", path: dir.path, sortOrder: 0)
        let store = WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))

        let files = makeProjectFileStore()
        writeProjectFile("""
        path: \(dir.path)
        tabs:
          - name: "Dev"
            split:
              direction: horizontal
              first:  { run: "npm run dev" }
              second: {}
        """, in: files)

        let priorActive = Preferences.shared.activeProjectID
        Preferences.shared.activeProjectID = project.id
        defer { Preferences.shared.activeProjectID = priorActive }

        let state = makeAppState(store: store, projectFiles: files)
        state.restoreSelection(projects: [project])

        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].customTitle == "Dev")
        #expect(ws.tabs[0].splitRoot.allPanes().count == 2)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func applyLayout_malformed_file_returns_error_and_does_not_apply() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        // Invalid: a `split` mapping missing its `second` child.
        writeProjectFile("path: \(root)\ntabs:\n  - split: { direction: horizontal, first: {} }\n", in: files)
        let error = state.applyLayout(project: p)

        #expect(error != nil)
        // Workspace is untouched — same tabs, nothing spawned or closed.
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func applyLayout_missing_file_returns_error_and_does_not_apply() throws {
        let state = makeAppState()
        let (p, _) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        let error = state.applyLayout(project: p)

        #expect(error != nil)
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func applyLayout_empty_tabs_returns_error_and_never_plans_destruction() throws {
        // A bare declaration (no tabs:) must read as "nothing to apply" —
        // planning against an empty tab list would close every live tab.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state)
        let beforeTabIDs = try #require(state.workspaces[p.id]).tabs.map(\.id)

        writeProjectFile("name: bare\npath: \(root)\n", in: files)
        let error = state.applyLayout(project: p)

        #expect(error != nil)
        #expect(state.workspaces[p.id]?.tabs.map(\.id) == beforeTabIDs)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func applyLayout_name_mismatch_applies_without_prompt() {
        // Files are matched by path; a differing `name:` is expected drift
        // (project renamed since last save), never a confirmation.
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state) // project name "proj"

        writeProjectFile("name: OtherApp\npath: \(root)\ntabs:\n  - {}\n", in: files)
        let error = state.applyLayout(project: p)

        #expect(error == nil)
        #expect(state.pendingLayoutApply == nil)
    }

    @Test
    func saveLayout_creates_central_file_declaring_the_project_path() throws {
        let files = makeProjectFileStore()
        let state = makeAppState(projectFiles: files)
        let (p, root) = seedProjectWithDir(state)

        let error = state.saveLayout(project: p)

        #expect(error == nil)
        let saved = try #require(try files.loadFull(forProjectPath: root))
        #expect(saved.name == "proj")
        #expect(saved.path == root)
        #expect(saved.tabs?.count == 1)
        #expect(files.find(forProjectPath: root)?.url.lastPathComponent == "proj.yaml")
    }

    // MARK: - panesToWarm (eager process start for focused project)

    @Test
    func panesToWarm_excludes_active_tab_includes_the_rest() {
        let pid = UUID()
        // Tab A (active): 1 pane. Tab B: 2-pane split. Tab C: 1 pane.
        let a = Pane(projectPath: "/p", projectID: pid)
        let (bTree, bIDs) = build(H(pane("b1"), pane("b2")))
        let c = Pane(projectPath: "/p", projectID: pid)
        let tabA = TerminalTab(id: UUID(), splitRoot: .pane(a), focusedPaneID: a.id)
        let tabB = TerminalTab(id: UUID(), splitRoot: bTree, focusedPaneID: nil)
        let tabC = TerminalTab(id: UUID(), splitRoot: .pane(c), focusedPaneID: c.id)
        let ws = Workspace(projectID: pid, tabs: [tabA, tabB, tabC], activeTabID: tabA.id)

        let warm = Set(AppState.panesToWarm(in: ws).map(\.id))
        // Active tab A's pane is NOT warmed (SwiftUI starts it); B's two + C are.
        #expect(!warm.contains(a.id))
        #expect(warm == Set([bIDs["b1"], bIDs["b2"], c.id].compactMap(\.self)))
        #expect(warm.count == 3)
    }

    @Test
    func panesToWarm_single_tab_workspace_warms_nothing() {
        let pid = UUID()
        let only = Pane(projectPath: "/p", projectID: pid)
        let tab = TerminalTab(id: UUID(), splitRoot: .pane(only), focusedPaneID: only.id)
        let ws = Workspace(projectID: pid, tabs: [tab], activeTabID: tab.id)
        #expect(AppState.panesToWarm(in: ws).isEmpty)
    }

    // MARK: - Quiet-settle

    // The poll calls `pane.settleTerminalActivityIfQuiet()` directly (no
    // occlusion special-casing): the OUTPUT_ACTIVITY heartbeat that sources
    // activity is occlusion-independent, so a quiet pane settles the same
    // whether or not it is on screen. These drive the settle in isolation —
    // deterministic (no live surface, no `Preferences` global) and a truer
    // unit than the full `refreshAllForegroundProcesses` tick, which re-reads
    // each pane's real foreground process (nil under test, clearing the run
    // source).

    /// A pane whose activity went quiet long ago (past the 3s settle window).
    private func quietRunningPane() -> Pane {
        let pane = Pane(projectPath: "/tmp", projectID: UUID())
        pane.recordUserInteraction()
        pane.markTerminalActivity(at: Date().addingTimeInterval(-10))
        #expect(pane.executionState == .running)
        return pane
    }

    @Test
    func quiet_activity_run_settles_to_done() {
        let pane = quietRunningPane()
        // 10s of silence is past the window — occluded or not, it's done.
        pane.settleTerminalActivityIfQuiet()
        #expect(pane.executionState == .done)
    }

    @Test
    func activity_run_holds_until_the_quiet_window_elapses() {
        let pane = Pane(projectPath: "/tmp", projectID: UUID())
        pane.recordUserInteraction()
        let start = Date()
        pane.markTerminalActivity(at: start)
        pane.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(2), quietInterval: 3)
        #expect(pane.executionState == .running)
        pane.settleTerminalActivityIfQuiet(now: start.addingTimeInterval(3), quietInterval: 3)
        #expect(pane.executionState == .done)
    }

    // MARK: - zmx session lifecycle on close paths

    /// A ZmxClient that records every killed session name. Remote kills are
    /// recorded into `remoteKilled` (when given) so a test can assert routing.
    private func recordingZmx(
        into killed: KilledSessions,
        remoteInto remoteKilled: KilledSessions? = nil
    ) -> ZmxClient {
        ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { name in await killed.append(name) },
            killRemoteSession: { _, name, _ in await (remoteKilled ?? killed).append(name) },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { [] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [], leaders: [:]) }
        )
    }

    @Test
    func closeTab_kills_every_panes_session() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let names = Set(tab.splitRoot.allPanes().map(\.sessionName))
        #expect(names.count == 2)

        // Second tab so the close leaves a valid workspace.
        _ = state.workspaces[p.id]?.createTab(projectPath: "/tmp")
        state.closeTab(tab.id, projectID: p.id)

        await killed.settle(expecting: names.count)
        #expect(await killed.names == names)
    }

    @Test
    func closing_remote_pane_routes_kill_over_ssh() async throws {
        // A remote pane's session lives on the remote daemon — a local kill
        // of its name would silently no-op and strand the session (#104).
        let killed = KilledSessions()
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed, remoteInto: remoteKilled)
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let target = try #require(tab.focusedPaneID)
        let targetName = try #require(tab.splitRoot.findPane(id: target)?.sessionName)

        state.closePane(target, projectID: p.id)

        await remoteKilled.settle(expecting: 1)
        #expect(await remoteKilled.names == [targetName])
        #expect(await killed.names.isEmpty)
    }

    // MARK: - Process-exit routing (#281)

    /// A ZmxClient whose orphan-sweep probe answers with a fixed listing (the
    /// process-exit liveness probe) and records remote kills.
    private func probeAnsweringZmx(
        entries: [ZmxSessionListParser.Entry]?,
        remoteKilled: KilledSessions
    ) -> ZmxClient {
        ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { _ in },
            killRemoteSession: { _, name, _ in await remoteKilled.append(name) },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in entries },
            listSessionsWithClients: { [] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [], leaders: [:]) }
        )
    }

    @Test
    func process_exit_closes_a_local_pane() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let p = seedProject(state)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let target = try #require(tab.focusedPaneID)
        let name = try #require(tab.splitRoot.findPane(id: target)?.sessionName)

        state.handleProcessExit(target, projectID: p.id)

        #expect(tab.splitRoot.findPane(id: target) == nil)
        await killed.settle(expecting: 1)
        #expect(await killed.names.contains(name))
    }

    @Test
    func remote_process_exit_keeps_the_pane_while_its_session_lives() async throws {
        // The drop case (#281): the ssh client died but the host still has
        // the session — the pane must survive for the reconnect sweep, and
        // nothing may kill the session.
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        state.zmx = probeAnsweringZmx(
            entries: [.init(name: pane.sessionName, clients: 0, owner: "us")],
            remoteKilled: remoteKilled
        )

        state.handleProcessExit(pane.id, projectID: p.id)

        await remoteKilled.settleExpectingNone()
        #expect(state.workspaces[p.id]?.activeTab?.splitRoot.findPane(id: pane.id) != nil)
        #expect(await remoteKilled.names.isEmpty)
    }

    @Test
    func remote_process_exit_keeps_the_pane_when_the_host_is_unreachable() async throws {
        // Fail-safe: no answer must never destroy the pane (wrongly keeping
        // one costs a manual close; wrongly closing one costs the session).
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        state.zmx = probeAnsweringZmx(entries: nil, remoteKilled: remoteKilled)

        state.handleProcessExit(pane.id, projectID: p.id)

        await remoteKilled.settleExpectingNone()
        #expect(state.workspaces[p.id]?.activeTab?.splitRoot.findPane(id: pane.id) != nil)
        #expect(await remoteKilled.names.isEmpty)
    }

    @Test
    func remote_process_exit_closes_the_pane_when_the_session_is_gone() async throws {
        // The deliberate end (typed `exit` killed the session): the host
        // positively reports it gone, so the pane closes as it always did.
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        // A second tab so the close leaves a valid workspace shape.
        _ = state.workspaces[p.id]?.createTab(projectPath: "devbox:~/dev/api")
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        state.zmx = probeAnsweringZmx(entries: [], remoteKilled: remoteKilled)

        state.handleProcessExit(pane.id, projectID: p.id)

        // The close happens after the async probe answers.
        await remoteKilled.settle(expecting: 1)
        #expect(state.workspaces[p.id]?.tabs.allSatisfy { $0.splitRoot.findPane(id: pane.id) == nil } == true)
    }

    @Test
    func remote_process_exit_keeps_the_pane_when_probes_are_disabled() async throws {
        // backgroundSSHConnections off (#272): no probe is allowed, so every
        // remote exit conservatively keeps the pane.
        let prior = Preferences.shared.backgroundSSHConnections
        defer { Preferences.shared.backgroundSSHConnections = prior }
        Preferences.shared.backgroundSSHConnections = false
        let remoteKilled = KilledSessions()
        let state = makeAppState()
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        state.zmx = probeAnsweringZmx(
            entries: [],
            remoteKilled: remoteKilled
        )

        state.handleProcessExit(pane.id, projectID: p.id)

        await remoteKilled.settleExpectingNone()
        #expect(state.workspaces[p.id]?.activeTab?.splitRoot.findPane(id: pane.id) != nil)
    }

    // MARK: - Background ssh connections toggle (#272)

    /// A ZmxClient whose foreground probe records each invocation. The kill
    /// paths are irrelevant here; only the probe seam matters.
    private func probeCountingZmx(into probes: KilledSessions) -> ZmxClient {
        ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { _ in },
            killRemoteSession: { _, _, _ in },
            remoteForegrounds: { _, _ in
                await probes.append(UUID().uuidString)
                return .unreachable
            },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { [] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [], leaders: [:]) }
        )
    }

    @Test
    func background_ssh_toggle_gates_every_remote_probe() async throws {
        let prior = Preferences.shared.backgroundSSHConnections
        defer { Preferences.shared.backgroundSSHConnections = prior }
        let probes = KilledSessions()
        let state = makeAppState()
        state.zmx = probeCountingZmx(into: probes)
        let p = seedProject(state, name: "remote", path: "devbox:~/dev/api")
        let pane = try #require(state.workspaces[p.id]?.activeTab?.splitRoot.allPanes().first)
        // Primed at init — the request that would bypass the resolver's
        // per-host interval AND the window-visibility filter, so this test
        // needs neither a visible window nor a 3s wait.
        #expect(pane.remoteProbePending)

        Preferences.shared.backgroundSSHConnections = false
        state.refreshAllForegroundProcesses()
        // The resolver consumes a pending request synchronously the moment it
        // fires the host's probe, so a still-pending request proves the tick
        // never reached the resolver — deterministic, no negative-wait.
        #expect(pane.remoteProbePending)
        #expect(await probes.names.isEmpty)

        Preferences.shared.backgroundSSHConnections = true
        state.refreshAllForegroundProcesses()
        #expect(!pane.remoteProbePending)
        await probes.settle(expecting: 1)
        #expect(await probes.names.count == 1)
    }

    @Test
    func closePane_kills_only_that_panes_session() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let p = seedProject(state)
        let tab = try #require(state.workspaces[p.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let target = try #require(tab.focusedPaneID)
        let targetName = try #require(tab.splitRoot.findPane(id: target)?.sessionName)

        state.closePane(target, projectID: p.id)

        await killed.settle(expecting: 1)
        #expect(await killed.names == [targetName])
    }

    @Test
    func unloadProject_kills_every_session_but_keeps_layout() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let p = seedProject(state)
        state.splitPane(direction: .horizontal, projectID: p.id)
        let names = try Set(
            #require(state.workspaces[p.id]).tabs
                .flatMap { $0.splitRoot.allPanes() }
                .map(\.sessionName)
        )
        #expect(names.count == 2)

        state.unloadProject(p.id)

        await killed.settle(expecting: names.count)
        // Sessions die (unload = stop the project's shells)…
        #expect(await killed.names == names)
        // …but the layout survives for the next open.
        let ws = try #require(state.workspaces[p.id])
        #expect(ws.tabs.count == 1)
        #expect(ws.tabs[0].splitRoot.allPanes().count == 2)
    }

    @Test
    func moveTab_kills_nothing() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let moving = try #require(state.workspaces[p1.id]?.tabs.first?.id)

        state.moveTab(moving, from: p1.id, to: p2.id, destPath: p2.path)

        await killed.settleExpectingNone()
        #expect(await killed.names.isEmpty)
    }

    @Test
    func moveTab_restamps_pane_routing_identity_but_not_session() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        let tab = try #require(state.workspaces[p1.id]?.activeTab)
        // Split so the moved tab carries more than one pane to restamp.
        state.splitPane(direction: .horizontal, projectID: p1.id)
        let panes = tab.splitRoot.allPanes()
        #expect(panes.count == 2)
        let originalSessionNames = Set(panes.map(\.sessionName))
        let originalPaths = Set(panes.map(\.projectPath))

        state.moveTab(tab.id, from: p1.id, to: p2.id, destPath: p2.path)

        // Routing identity (projectID) is restamped to the destination so a
        // notification click navigates to the right workspace.
        #expect(tab.splitRoot.allPanes().allSatisfy { $0.projectID == p2.id })
        // Session identity is untouched — the shells keep running under their
        // original names and paths (a remote pane would still kill over ssh).
        #expect(Set(tab.splitRoot.allPanes().map(\.sessionName)) == originalSessionNames)
        #expect(Set(tab.splitRoot.allPanes().map(\.projectPath)) == originalPaths)
    }

    @Test
    func moveTab_toIndex_inserts_at_slot_in_destination() throws {
        let state = makeAppState()
        let p1 = seedProject(state, name: "p1", path: "/tmp1")
        let p2 = seedProject(state, name: "p2", path: "/tmp2")
        // Give p2 two tabs so there's a middle slot to drop into.
        let dest = try #require(state.workspaces[p2.id])
        let d0 = dest.tabs[0].id
        let d1 = dest.createTab(projectPath: p2.path).id
        let moving = try #require(state.workspaces[p1.id]?.activeTab)

        state.moveTab(moving.id, from: p1.id, to: p2.id, destPath: p2.path, toIndex: 1)

        #expect(dest.tabs.map(\.id) == [d0, moving.id, d1])
        #expect(dest.activeTabID == moving.id)
        #expect(state.workspaces[p1.id]?.tabs.contains { $0.id == moving.id } == false)
    }

    @Test
    func reorderTab_moves_within_project_and_persists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspaces.json")
        let state = makeAppState(store: WorkspaceStore(fileURL: storeURL))
        let p = seedProject(state, name: "p", path: "/tmp")
        let ws = try #require(state.workspaces[p.id])
        let t1 = ws.tabs[0].id
        let t2 = ws.createTab(projectPath: p.path).id

        state.reorderTab(t1, inProject: p.id, toIndex: 2)
        #expect(ws.tabs.map(\.id) == [t2, t1])

        // The reorder persisted: a fresh store reading the same file sees it.
        let reloaded = WorkspaceStore(fileURL: storeURL).load()
        let saved = try #require(reloaded.workspaces.first { $0.projectID == p.id })
        #expect(saved.tabs.map(\.id) == [t2, t1])
    }

    // MARK: - Busy-close confirmations

    @Test
    func requestCloseTab_with_idle_panes_closes_immediately() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        _ = ws.createTab(projectPath: "/tmp")

        // No live surfaces in a unit test → needsConfirmQuit is unreachable →
        // not busy → closes without staging.
        state.requestCloseTab(tab.id, projectID: p.id)
        #expect(state.pendingCloseTab == nil)
        #expect(ws.tabs.count == 1)
    }

    @Test
    func requestRemoveProject_idle_runs_removal_immediately() {
        let state = makeAppState()
        let p = seedProject(state)
        var removed = false
        state.requestRemoveProject(p.id) { removed = true }
        #expect(removed)
        #expect(state.pendingRemoveProject == nil)
    }

    @Test
    func pendingCloseTab_confirm_and_cancel() throws {
        let state = makeAppState()
        let p = seedProject(state)
        let ws = try #require(state.workspaces[p.id])
        let tab = try #require(ws.activeTab)
        _ = ws.createTab(projectPath: "/tmp")

        // Stage manually (busy detection needs a live surface).
        state.pendingCloseTab = AppState.PendingCloseTab(tabID: tab.id, projectID: p.id)
        state.cancelPendingCloseTab()
        #expect(state.pendingCloseTab == nil)
        #expect(ws.tabs.count == 2)

        state.pendingCloseTab = AppState.PendingCloseTab(tabID: tab.id, projectID: p.id)
        state.confirmPendingCloseTab()
        #expect(state.pendingCloseTab == nil)
        #expect(ws.tabs.count == 1)
    }

    @Test
    func beginSecurityScopedAccess_unused_does_not_regrant_on_debug() {
        let state = makeAppState()
        let project = Project(name: "cli", path: "/tmp/cli-project")
        state.beginSecurityScopedAccess(for: project)
        #expect(AppDistribution.isAppStore == false)
        #expect(state.pendingSecurityScopeRegrantID == nil)
        #expect(!state.isHoldingSecurityScopedAccess(for: project.id))
    }

    @Test
    func requestSecurityScopeRegrant_queues_after_the_first() {
        let state = makeAppState()
        let a = UUID()
        let b = UUID()
        state.requestSecurityScopeRegrant(for: a)
        state.requestSecurityScopeRegrant(for: b)
        #expect(state.pendingSecurityScopeRegrantID == a)
        state.requestSecurityScopeRegrant(for: a)
        #expect(state.pendingSecurityScopeRegrantID == a)
    }

    @Test
    func warmFocusedProject_skips_local_panes_until_mas_folder_grant() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-grant-warm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = makeAppState()
        state.zmx = .noop
        state.folderGrantUsesSecurityScope = true
        var warmed: [UUID] = []
        state.warmPane = { warmed.append($0.id) }

        let project = Project(name: "cli", path: dir.path)
        state.selectProject(project)
        let ws = try #require(state.workspaces[project.id])
        _ = ws.createTab(projectPath: dir.path)
        warmed.removeAll()
        state.warmFocusedProject()

        #expect(state.pendingSecurityScopeRegrantID == project.id)
        #expect(!state.isHoldingSecurityScopedAccess(for: project.id))
        #expect(warmed.isEmpty)

        let store = makeProjectStore()
        store.add(project)
        state.pendingSecurityScopeRegrantID = nil
        let outcome = state.completeSecurityScopeRegrant(
            store: store,
            projectID: project.id,
            pickedURL: URL(fileURLWithPath: dir.path)
        )
        #expect(outcome == .granted)
        #expect(state.isHoldingSecurityScopedAccess(for: project.id))
        #expect(!warmed.isEmpty)
        #expect(state.pendingSecurityScopeRegrantID == nil)
        #expect(try state.shouldSpawnPane(
            #require(ws.tabs[1].splitRoot.allPanes().first),
            workspaceID: project.id
        ))
    }

    @Test
    func applySuccessfulFolderGrant_kills_denied_cwd_session_for_first_spawn() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-grant-kill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = makeAppState()
        state.folderGrantUsesSecurityScope = true
        state.warmPane = { _ in }
        let killed = OSAllocatedUnfairLock(initialState: [String]())
        let killSession: @Sendable (String) async -> Void = { name in
            killed.withLock { $0.append(name) }
        }
        state.zmx = ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: killSession,
            killRemoteSession: { _, _, _ in },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { [] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [], leaders: [:]) }
        )

        let project = Project(name: "cli", path: dir.path)
        state.selectProject(project)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.splitRoot.allPanes().first)
        _ = pane.ensureNSView()
        #expect(pane.hasBuiltSurface)
        #expect(pane.nsView != nil)
        #expect(!state.shouldSpawnPane(pane, workspaceID: project.id))

        let store = makeProjectStore()
        store.add(project)
        state.pendingSecurityScopeRegrantID = nil
        let tickBefore = pane.surfaceReattachTick
        let outcome = state.completeSecurityScopeRegrant(
            store: store,
            projectID: project.id,
            pickedURL: URL(fileURLWithPath: dir.path)
        )
        #expect(outcome == .granted)
        #expect(pane.nsView == nil)
        #expect(!pane.hasBuiltSurface)
        #expect(pane.surfaceReattachTick > tickBefore)
        #expect(killed.withLock { $0 } == [pane.sessionName])
        #expect(state.folderGrantEpoch > 0)
        #expect(state.shouldSpawnPane(pane, workspaceID: project.id))
    }

    @Test
    func shouldSpawnPane_ordinary_workspace_requires_held_grant_covers_cwd() throws {
        let aDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-grant-src-\(UUID().uuidString)", isDirectory: true)
        let bDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-grant-dst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: aDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: aDir)
            try? FileManager.default.removeItem(at: bDir)
        }

        let state = makeAppState()
        state.zmx = .noop
        state.warmPane = { _ in }
        state.folderGrantUsesSecurityScope = true

        let source = Project(name: "src", path: aDir.path)
        let dest = Project(name: "dst", path: bDir.path)
        state.selectProject(source)
        _ = try #require(state.workspaces[source.id]).createTab(projectPath: aDir.path)
        state.selectProject(dest)

        let store = makeProjectStore()
        store.add(source)
        store.add(dest)
        state.pendingSecurityScopeRegrantID = nil
        #expect(state.completeSecurityScopeRegrant(
            store: store,
            projectID: dest.id,
            pickedURL: URL(fileURLWithPath: bDir.path)
        ) == .granted)

        let moving = try #require(state.workspaces[source.id]?.tabs.last)
        let pane = try #require(moving.splitRoot.allPanes().first)
        state.moveTab(moving.id, from: source.id, to: dest.id, destPath: dest.path)
        #expect(pane.projectID == dest.id)
        #expect(pane.projectPath == aDir.path)
        #expect(!state.shouldSpawnPane(pane, workspaceID: dest.id))

        let destHome = try #require(
            state.workspaces[dest.id]?.tabs
                .first { $0.id != moving.id }?
                .splitRoot.allPanes().first
        )
        #expect(destHome.projectPath == bDir.path)
        #expect(state.shouldSpawnPane(destHome, workspaceID: dest.id))
    }

    @Test
    func shouldSpawnPane_held_grant_covers_unresolved_var_temp_path() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-grant-var-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let varPath = dir.path.hasPrefix("/private/var/")
            ? String(dir.path.dropFirst("/private".count))
            : dir.path
        try #require(varPath.hasPrefix("/var/"))
        let privatePath = varPath.hasPrefix("/private/") ? varPath : "/private" + varPath

        let state = makeAppState()
        state.zmx = .noop
        state.warmPane = { _ in }
        state.folderGrantUsesSecurityScope = true

        let project = Project(name: "tmp", path: varPath)
        state.selectProject(project)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.splitRoot.allPanes().first)
        #expect(pane.projectPath == varPath)
        #expect(!state.shouldSpawnPane(pane, workspaceID: project.id))

        let store = makeProjectStore()
        store.add(project)
        state.pendingSecurityScopeRegrantID = nil
        #expect(state.completeSecurityScopeRegrant(
            store: store,
            projectID: project.id,
            pickedURL: URL(fileURLWithPath: privatePath, isDirectory: true)
        ) == .granted)
        #expect(state.shouldSpawnPane(pane, workspaceID: project.id))
    }

    @Test
    func beginFolderGrant_bumps_epoch_when_mas_grant_is_newly_held() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-grant-epoch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = makeAppState()
        state.zmx = .noop
        state.warmPane = { _ in }
        state.folderGrantUsesSecurityScope = true
        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let project = Project(name: "proj", path: dir.path, securityScopedBookmark: bookmark)
        #expect(state.folderGrantEpoch == 0)

        state.selectProject(project)
        #expect(state.isHoldingSecurityScopedAccess(for: project.id))
        #expect(state.folderGrantEpoch == 1)

        // Already focused: begin is idempotent and must not keep bumping.
        state.selectProject(project)
        #expect(state.folderGrantEpoch == 1)
    }

    @Test
    func completeSecurityScopeRegrant_wrong_folder_requeues_cancel_does_not() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-grant-wrong-\(UUID().uuidString)", isDirectory: true)
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-grant-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: other)
        }

        let state = makeAppState()
        state.folderGrantUsesSecurityScope = true
        let store = makeProjectStore()
        let project = store.create(name: "proj", path: dir.path)
        state.requestSecurityScopeRegrant(for: project.id)
        #expect(state.pendingSecurityScopeRegrantID == project.id)
        state.pendingSecurityScopeRegrantID = nil

        let wrong = state.completeSecurityScopeRegrant(
            store: store,
            projectID: project.id,
            pickedURL: URL(fileURLWithPath: other.path)
        )
        #expect(wrong == .wrongFolder)
        #expect(state.pendingSecurityScopeRegrantID == project.id)

        state.pendingSecurityScopeRegrantID = nil
        let cancelled = state.completeSecurityScopeRegrant(
            store: store,
            projectID: project.id,
            pickedURL: nil
        )
        #expect(cancelled == .dismissed)
        #expect(state.pendingSecurityScopeRegrantID == nil)
    }

    @Test
    func replace_project_path_parent_grant_remints_descendant_not_sibling() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-replace-parent-\(UUID().uuidString)", isDirectory: true)
        let projectDir = parent.appendingPathComponent("proj", isDirectory: true)
        let descendant = projectDir.appendingPathComponent("src", isDirectory: true)
        let sibling = parent.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let store = makeProjectStore()
        let project = store.create(name: "proj", path: projectDir.path)
        let state = makeAppState()
        state.zmx = .noop
        state.warmPane = { _ in }
        state.folderGrantUsesSecurityScope = true
        state.selectProject(project)
        state.pendingSecurityScopeRegrantID = nil
        let granted = state.completeSecurityScopeRegrant(
            store: store,
            projectID: project.id,
            pickedURL: parent
        )
        #expect(granted == .granted)
        #expect(state.isHoldingSecurityScopedAccess(for: project.id))

        let replaced = state.commitReplacedProjectPath(
            projectStore: store,
            projectID: project.id,
            newPath: descendant.path,
            pickedURL: nil
        )
        #expect(replaced)
        let updated = try #require(store.projects.first { $0.id == project.id })
        #expect(updated.path == ProjectPath.normalizedForStorage(descendant.path))
        let bookmark = try #require(updated.securityScopedBookmark)
        let resolved = try #require(SecurityScopedBookmark.resolve(bookmark))
        #expect(SecurityScopedBookmark.folder(resolved.url.path, covers: descendant.path))
        #expect(ProjectPath.canonicalLocal(resolved.url.path) != ProjectPath.canonicalLocal(sibling.path))
        #expect(!SecurityScopedBookmark.folder(sibling.path, covers: descendant.path))
        #expect(state.isHoldingSecurityScopedAccess(for: project.id))
    }

    @Test
    func replace_project_path_keeps_covering_bookmark_for_descendant() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-replace-cover-\(UUID().uuidString)", isDirectory: true)
        let child = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = makeProjectStore()
        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let project = store.create(name: "proj", path: dir.path, securityScopedBookmark: bookmark)
        let state = makeAppState()
        state.folderGrantUsesSecurityScope = true
        state.selectProject(project)

        let replaced = state.commitReplacedProjectPath(
            projectStore: store,
            projectID: project.id,
            newPath: child.path,
            pickedURL: nil
        )
        #expect(replaced)
        let updated = try #require(store.projects.first { $0.id == project.id })
        #expect(updated.path == ProjectPath.normalizedForStorage(child.path))
        #expect(updated.securityScopedBookmark != nil)
        #expect(state.isHoldingSecurityScopedAccess(for: project.id))
    }

    @Test
    func replace_project_path_requires_pick_before_leaving_granted_tree() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-replace-old-\(UUID().uuidString)", isDirectory: true)
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-replace-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: other)
        }

        let store = makeProjectStore()
        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let project = store.create(name: "proj", path: dir.path, securityScopedBookmark: bookmark)
        let state = makeAppState()
        state.folderGrantUsesSecurityScope = true
        state.selectProject(project)

        let cancelled = state.commitReplacedProjectPath(
            projectStore: store,
            projectID: project.id,
            newPath: other.path,
            pickedURL: nil
        )
        #expect(!cancelled)
        let afterCancel = try #require(store.projects.first { $0.id == project.id })
        #expect(afterCancel.path == ProjectPath.normalizedForStorage(dir.path))
        #expect(afterCancel.securityScopedBookmark == bookmark)

        let replaced = state.commitReplacedProjectPath(
            projectStore: store,
            projectID: project.id,
            newPath: other.path,
            pickedURL: other
        )
        #expect(replaced)
        let updated = try #require(store.projects.first { $0.id == project.id })
        #expect(updated.path == ProjectPath.normalizedForStorage(other.path))
        #expect(updated.securityScopedBookmark != nil)
        #expect(updated.securityScopedBookmark != bookmark)
        #expect(state.isHoldingSecurityScopedAccess(for: project.id))
    }

    @Test
    func replace_project_path_refreshes_pinned_origin_stamp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-replace-pin-\(UUID().uuidString)", isDirectory: true)
        let child = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = makeProjectStore()
        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let project = store.create(name: "proj", path: dir.path, securityScopedBookmark: bookmark)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-replace-pin-\(UUID().uuidString).json")
        let state = makeAppState(store: WorkspaceStore(fileURL: storeURL))
        state.zmx = .noop
        state.warmPane = { _ in }
        state.folderGrantUsesSecurityScope = true
        state.selectProject(project)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        state.pinTab(tab.id, fromProject: project.id)
        #expect(state.pinnedRecords.first?.originFolderPath == project.path)
        let leftoverPath = pane.projectPath
        #expect(SecurityScopedBookmark.folder(dir.path, covers: leftoverPath))
        #expect(!SecurityScopedBookmark.folder(child.path, covers: leftoverPath))

        let replaced = state.commitReplacedProjectPath(
            projectStore: store,
            projectID: project.id,
            newPath: child.path,
            pickedURL: nil
        )
        #expect(replaced)
        let updated = try #require(store.projects.first { $0.id == project.id })
        let record = try #require(state.pinnedRecords.first)
        #expect(record.originFolderPath == updated.path)
        #expect(record.originFolderBookmark == updated.securityScopedBookmark)
        #expect(record.originFolderPath != ProjectPath.normalizedForStorage(dir.path))
        #expect(record.coveringGrants.contains {
            $0.id == record.id && SecurityScopedBookmark.folder($0.folderPath, covers: leftoverPath)
        })
        #expect(record.coveringGrants.contains {
            $0.id == record.id && $0.folderBookmark == bookmark
        })
        #expect(
            state.shouldSpawnPane(pane, workspaceID: PinnedTabs.projectID)
                || state.pendingSecurityScopeRegrantID == record.id
        )
        #expect(WorkspaceStore(fileURL: storeURL).load().pinned.first?.coveringGrants?.contains {
            $0.id == record.id && SecurityScopedBookmark.folder($0.folderPath, covers: leftoverPath)
        } == true)
    }

    @Test
    func replace_project_path_restore_spawns_leftover_dest_cwd() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-replace-pin-restore-\(UUID().uuidString)", isDirectory: true)
        let child = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = makeProjectStore()
        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let project = store.create(name: "proj", path: dir.path, securityScopedBookmark: bookmark)
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-replace-pin-restore-\(UUID().uuidString).json")
        let projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-replace-pin-restore-projects-\(UUID().uuidString)", isDirectory: true)
        let state = makeAppState(
            store: WorkspaceStore(fileURL: storeURL),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
        state.zmx = .noop
        state.warmPane = { _ in }
        state.folderGrantUsesSecurityScope = true
        state.selectProject(project)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        let leftoverPath = pane.projectPath
        state.pinTab(tab.id, fromProject: project.id)
        #expect(state.commitReplacedProjectPath(
            projectStore: store,
            projectID: project.id,
            newPath: child.path,
            pickedURL: nil
        ))
        let updated = try #require(store.projects.first { $0.id == project.id })
        let recordID = try #require(state.pinnedRecords.first?.id)

        let state2 = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
        var unknown = ZmxClient.noop
        unknown.isBundled = { true }
        unknown.listSessionsWithClients = { nil }
        state2.zmx = unknown
        state2.warmPane = { _ in }
        state2.folderGrantUsesSecurityScope = true
        let loaded = WorkspaceStore(fileURL: storeURL).load()
        state2.restorePinnedState(loaded.pinned)
        await state2.materializeRestoredPinnedTabs(projects: [updated])
        state2.beginSecurityScopedAccessForPinnedOrigins(projects: [updated])

        let restored = try #require(state2.pinnedWorkspace?.tabs.first { $0.id == recordID })
        let leftover = try #require(
            restored.splitRoot.allPanes().first { $0.projectPath == leftoverPath }
        )
        #expect(state2.pinnedRecords.first?.originFolderPath == updated.path)
        #expect(state2.pinnedRecords.first?.coveringGrants.contains {
            $0.id == recordID && SecurityScopedBookmark.folder($0.folderPath, covers: leftoverPath)
        } == true)
        #expect(
            state2.shouldSpawnPane(leftover, workspaceID: PinnedTabs.projectID)
                || state2.pendingSecurityScopeRegrantID == recordID
        )
    }

    @Test
    func pinned_origin_gone_queues_folder_grant_for_pane_cwd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-pinned-gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = makeProjectStore()
        let project = store.create(name: "origin", path: dir.path)
        let state = makeAppState()
        state.zmx = .noop
        state.warmPane = { _ in }
        state.folderGrantUsesSecurityScope = true
        state.selectProject(project)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        state.pinTab(tab.id, fromProject: project.id)
        store.remove(id: project.id)
        state.pendingSecurityScopeRegrantID = nil

        state.beginSecurityScopedAccessForPinnedOrigins(projects: store.projects)
        #expect(state.pendingSecurityScopeRegrantID == project.id)
        #expect(!state.shouldSpawnPane(pane, workspaceID: PinnedTabs.projectID))

        state.pendingSecurityScopeRegrantID = nil
        let outcome = state.completeSecurityScopeRegrant(
            store: store,
            projectID: project.id,
            pickedURL: URL(fileURLWithPath: dir.path)
        )
        #expect(outcome == .granted)
        #expect(state.isHoldingSecurityScopedAccess(for: project.id))
        #expect(state.shouldSpawnPane(pane, workspaceID: PinnedTabs.projectID))
        #expect(state.pinnedRecords.first?.originFolderBookmark != nil)
    }

    @Test
    func unload_and_remove_keep_folder_grant_for_pinned_origin() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-pinned-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = makeProjectStore()
        let bookmark = try #require(SecurityScopedBookmark.create(from: dir))
        let project = store.create(
            name: "origin",
            path: dir.path,
            securityScopedBookmark: bookmark
        )
        let state = makeAppState()
        state.zmx = .noop
        state.warmPane = { _ in }
        state.folderGrantUsesSecurityScope = true
        state.selectProject(project)
        #expect(state.isHoldingSecurityScopedAccess(for: project.id))
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let pane = try #require(tab.splitRoot.allPanes().first)
        state.pinTab(tab.id, fromProject: project.id)

        state.unloadProject(project.id)
        #expect(state.isHoldingSecurityScopedAccess(for: project.id))
        #expect(state.shouldSpawnPane(pane, workspaceID: PinnedTabs.projectID))

        state.preservePinnedOriginGrant(from: store.projects.first { $0.id == project.id } ?? project)
        state.removeProject(project.id)
        store.remove(id: project.id)
        #expect(state.isHoldingSecurityScopedAccess(for: project.id))
        #expect(state.pinnedRecords.first?.originFolderBookmark == bookmark)
        #expect(state.shouldSpawnPane(pane, workspaceID: PinnedTabs.projectID))

        let state2 = makeAppState()
        state2.zmx = .noop
        state2.warmPane = { _ in }
        state2.folderGrantUsesSecurityScope = true
        state2.pinnedRecords = state.pinnedRecords
        state2.ensurePinnedWorkspace()
        state2.beginSecurityScopedAccessForPinnedOrigins(projects: [])
        #expect(state2.isHoldingSecurityScopedAccess(for: project.id))
        #expect(state2.pendingSecurityScopeRegrantID == nil)
    }

    @Test
    func focusing_project_without_selectProject_queues_mas_folder_grant() throws {
        let state = makeAppState()
        state.zmx = .noop
        state.warmPane = { _ in }
        state.folderGrantUsesSecurityScope = true
        let a = seedProject(state, name: "a", path: "/tmp/a-\(UUID().uuidString)")
        let b = seedProject(state, name: "b", path: "/tmp/b-\(UUID().uuidString)")
        state.pendingSecurityScopeRegrantID = nil

        state.selectGlobalTab(.previous, projects: [a, b])
        #expect(state.activeProjectID == a.id)
        #expect(state.pendingSecurityScopeRegrantID == a.id)

        state.pendingSecurityScopeRegrantID = nil
        let pane = try #require(state.workspaces[b.id]?.activeTab?.splitRoot.allPanes().first)
        state.navigateToPane(pane.id, projectID: b.id)
        #expect(state.activeProjectID == b.id)
        #expect(state.pendingSecurityScopeRegrantID == b.id)

        state.pendingSecurityScopeRegrantID = nil
        let tab = try #require(state.workspaces[a.id]?.activeTab)
        state.moveTab(tab.id, from: a.id, to: b.id, destPath: b.path)
        #expect(state.activeProjectID == b.id)
        #expect(state.pendingSecurityScopeRegrantID == b.id)
    }

    @Test
    func originless_pinned_tab_is_not_granted_on_mas() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-originless-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let state = makeAppState()
        state.zmx = .noop
        state.warmPane = { _ in }
        state.folderGrantUsesSecurityScope = true
        state.ensurePinnedWorkspace()
        let tab = try #require(state.workspaces[PinnedTabs.projectID]?.createTab(projectPath: dir.path))
        let pane = try #require(tab.splitRoot.allPanes().first)
        state.saveWorkspaces()
        let record = try #require(state.pinnedRecords.first { $0.id == tab.id })
        #expect(record.originProjectID == nil)
        #expect(!state.shouldSpawnPane(pane, workspaceID: PinnedTabs.projectID))
        #expect(state.pendingSecurityScopeRegrantID == record.id)

        state.pendingSecurityScopeRegrantID = nil
        let store = makeProjectStore()
        let outcome = state.completeSecurityScopeRegrant(
            store: store,
            projectID: record.id,
            pickedURL: URL(fileURLWithPath: dir.path)
        )
        #expect(outcome == .granted)
        #expect(state.isHoldingSecurityScopedAccess(for: record.id))
        #expect(state.shouldSpawnPane(pane, workspaceID: PinnedTabs.projectID))
    }

    // MARK: - addOrSelectProject (POR-336)

    @Test
    func addOrSelectProject_reuses_existing_local_path() {
        let state = makeAppState()
        let store = makeProjectStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-add-or-select-\(UUID().uuidString)", isDirectory: true)
            .path
        let existing = store.create(name: "existing", path: base)

        let project = state.addOrSelectProject(
            store: store,
            name: "duplicate",
            path: base + "/./"
        )

        #expect(project.id == existing.id)
        #expect(project.name == "existing")
        #expect(store.projects.count == 1)
        #expect(state.activeProjectID == existing.id)
    }

    @Test
    func addOrSelectProject_creates_when_no_match() {
        let state = makeAppState()
        let store = makeProjectStore()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-add-or-select-new-\(UUID().uuidString)", isDirectory: true)
            .path

        let project = state.addOrSelectProject(store: store, name: "fresh", path: path)

        #expect(store.projects.count == 1)
        #expect(project.name == "fresh")
        #expect(state.activeProjectID == project.id)
        #expect(store.projects.first?.id == project.id)
    }

    @Test
    func addOrSelectProject_creates_remote_when_no_match() {
        let state = makeAppState()
        let store = makeProjectStore()

        let project = state.addOrSelectProject(
            store: store,
            name: "api",
            path: "devbox:~/dev/new",
            zmxPath: "~/bin/zmx"
        )

        #expect(store.projects.count == 1)
        #expect(project.name == "api")
        #expect(project.zmxPath == "~/bin/zmx")
        #expect(state.activeProjectID == project.id)
    }

    @Test
    func addOrSelectProject_reuses_remote_without_rewriting_zmxPath() {
        let state = makeAppState()
        let store = makeProjectStore()
        let existing = store.create(name: "api", path: "devbox:~/dev/api")

        let project = state.addOrSelectProject(
            store: store,
            name: "duplicate",
            path: "devbox:~/dev/api",
            zmxPath: "~/bin/zmx"
        )

        #expect(project.id == existing.id)
        #expect(project.zmxPath == nil)
        #expect(store.projects.count == 1)
        #expect(state.activeProjectID == existing.id)
    }

    @Test
    func addOrSelectProject_selects_first_match_when_two_share_a_path() {
        let state = makeAppState()
        let store = makeProjectStore()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-add-or-select-dup-\(UUID().uuidString)", isDirectory: true)
            .path
        let first = store.create(name: "one", path: path)
        let second = store.create(name: "two", path: path + "/./")
        #expect(first.id != second.id)
        #expect(store.projects.count == 2)

        let project = state.addOrSelectProject(store: store, name: "third", path: path)

        #expect(project.id == first.id)
        #expect(store.projects.count == 2)
        #expect(state.activeProjectID == first.id)
    }

    // MARK: - Session inventory sheet (POR-444)

    private func stubSessionZmx(
        _ state: AppState,
        entries: [ZmxSessionListParser.Entry]?,
        leaders: [String: pid_t] = [:]
    ) {
        state.zmx = ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { _ in },
            killRemoteSession: { _, _, _ in },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { entries },
            sessionLeaderPIDs: { leaders },
            sessionListSnapshot: { entries.map { (entries: $0, leaders: leaders) } }
        )
    }

    @Test
    func refreshSessionInventory_maps_attached_and_unattached_from_stub_snapshot() async throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/tmp/kectil")
        let pane = try #require(state.workspaces[project.id]?.activeTab?.splitRoot.allPanes().first)
        let unattached = "futuraterm-kectil-bbbbbbbbbbbb"
        stubSessionZmx(
            state,
            entries: [
                .init(name: pane.sessionName, clients: 1),
                .init(name: unattached, clients: 0),
            ]
        )
        let snapshot = await state.zmx.sessionListSnapshot()
        state.applySessionInventorySnapshot(
            snapshot,
            projects: [project],
            inspect: { _ in (nil, nil) }
        )
        #expect(state.sessionInventoryUnavailable == false)
        #expect(state.sessionInventoryRows.count == 2)
        let attached = try #require(state.sessionInventoryRows.first { $0.name == pane.sessionName })
        #expect(attached.attachment == .attached)
        #expect(attached.claim?.projectName == "Kectil")
        let orphan = try #require(state.sessionInventoryRows.first { $0.name == unattached })
        #expect(orphan.attachment == .unattached)
        #expect(orphan.claim == nil)
    }

    @Test
    func refreshSessionInventory_nil_snapshot_is_unavailable_not_a_crash() async {
        let state = makeAppState()
        let project = seedProject(state)
        stubSessionZmx(state, entries: nil)
        let snapshot = await state.zmx.sessionListSnapshot()
        state.applySessionInventorySnapshot(snapshot, projects: [project], inspect: { _ in (nil, nil) })
        #expect(snapshot == nil)
        #expect(state.sessionInventoryUnavailable)
        #expect(state.sessionInventoryRows.isEmpty)
    }

    @Test
    func refreshSessionInventory_live_gather_is_noop_in_tests() async {
        let state = makeAppState()
        let project = seedProject(state)
        await state.refreshSessionInventory(projects: [project])
        #expect(state.sessionInventoryRows.isEmpty)
        #expect(state.sessionInventoryUnavailable == false)
    }

    @Test
    func refreshLocalListeners_is_noop_in_tests() async {
        let state = makeAppState()
        let project = seedProject(state)
        await state.refreshLocalListeners(projects: [project])
        #expect(state.localListenerRows.isEmpty)
        #expect(state.localListenerUnavailable == false)
        #expect(state.isLocalListenerLoading == false)
    }

    @Test
    func applyLocalListenerSnapshot_unavailable_sets_flag() {
        let state = makeAppState()
        state.applyLocalListenerSnapshot(.unavailable)
        #expect(state.localListenerUnavailable)
        #expect(state.localListenerRows.isEmpty)
    }

    @Test
    func applyLocalListenerSnapshot_ready_publishes_row() {
        let state = makeAppState()
        let row = LocalListenerInventory.Row(
            id: "42:3000",
            pid: 42,
            command: "node",
            port: 3000,
            address: "127.0.0.1",
            displayURL: "http://127.0.0.1:3000",
            cwd: "/tmp/app",
            argvSummary: "node server.js",
            projectName: "App",
            projectID: nil
        )
        state.applyLocalListenerSnapshot(.ready([row]))
        #expect(state.localListenerUnavailable == false)
        #expect(state.localListenerRows == [row])
    }

    @Test
    func killLocalListeners_empty_ids_never_signals() async {
        let state = makeAppState()
        let project = seedProject(state)
        var signaled: [pid_t] = []
        await state.killLocalListeners(ids: [], projects: [project], signal: { pid in
            signaled.append(pid)
            return 0
        })
        #expect(signaled.isEmpty)
    }

    @Test
    func killLocalListeners_unknown_id_is_noop() async {
        let state = makeAppState()
        let project = seedProject(state)
        state.applyLocalListenerSnapshot(.ready([listenerRow(id: "42:3000", pid: 42, port: 3000)]))
        var signaled: [pid_t] = []
        await state.killLocalListeners(ids: ["missing"], projects: [project], signal: { pid in
            signaled.append(pid)
            return 0
        })
        #expect(signaled.isEmpty)
    }

    @Test
    func killLocalListeners_same_pid_two_ports_signals_once() async {
        let state = makeAppState()
        let project = seedProject(state)
        let pid = livePidForKillTests()
        let started = ProcessInspector.startDate(pid: pid)
        state.applyLocalListenerSnapshot(.ready([
            listenerRow(id: "\(pid):3000", pid: pid, port: 3000, startDate: started),
            listenerRow(id: "\(pid):3001", pid: pid, port: 3001, command: "node", startDate: started),
        ]))
        var signaled: [pid_t] = []
        await state.killLocalListeners(
            ids: ["\(pid):3000", "\(pid):3001"],
            projects: [project],
            signal: { p in
                signaled.append(p)
                return 0
            }
        )
        #expect(signaled == [pid])
    }

    @Test
    func killLocalListeners_skips_pid_1() async {
        let state = makeAppState()
        let project = seedProject(state)
        state.applyLocalListenerSnapshot(.ready([listenerRow(id: "1:80", pid: 1, port: 80, command: "launchd")]))
        var signaled: [pid_t] = []
        await state.killLocalListeners(ids: ["1:80"], projects: [project], signal: { pid in
            signaled.append(pid)
            return 0
        })
        #expect(signaled.isEmpty)
    }

    @Test
    func killLocalListeners_skips_self_pid() async {
        let state = makeAppState()
        let project = seedProject(state)
        let selfPid = ProcessInfo.processInfo.processIdentifier
        state.applyLocalListenerSnapshot(.ready([
            listenerRow(id: "\(selfPid):9", pid: selfPid, port: 9, command: "FuturaTerm"),
        ]))
        var signaled: [pid_t] = []
        await state.killLocalListeners(ids: ["\(selfPid):9"], projects: [project], signal: { pid in
            signaled.append(pid)
            return 0
        })
        #expect(signaled.isEmpty)
    }

    @Test
    func killLocalListeners_happy_path_records_pid() async {
        let state = makeAppState()
        let project = seedProject(state)
        let pid = livePidForKillTests()
        let started = ProcessInspector.startDate(pid: pid)
        state.applyLocalListenerSnapshot(.ready([
            listenerRow(id: "\(pid):5173", pid: pid, port: 5173, startDate: started),
        ]))
        var signaled: [pid_t] = []
        await state.killLocalListeners(ids: ["\(pid):5173"], projects: [project], signal: { p in
            signaled.append(p)
            return 0
        })
        #expect(signaled == [pid])
    }

    @Test
    func killLocalListeners_skips_startDate_mismatch() async {
        let state = makeAppState()
        let project = seedProject(state)
        let pid = livePidForKillTests()
        state.applyLocalListenerSnapshot(.ready([
            listenerRow(id: "\(pid):5173", pid: pid, port: 5173, startDate: Date.distantPast),
        ]))
        var signaled: [pid_t] = []
        await state.killLocalListeners(ids: ["\(pid):5173"], projects: [project], signal: { p in
            signaled.append(p)
            return 0
        })
        #expect(signaled.isEmpty)
    }

    @Test
    func macMoonlightAvailable_probes_bundle_id_then_applications_path() {
        #expect(
            AppState.macMoonlightAvailable(
                bundleURL: { _ in nil },
                appExists: { _ in false },
                probePATH: false
            )
                == false
        )
        #expect(
            AppState.macMoonlightAvailable(
                bundleURL: { id in
                    id == "com.moonlight-stream.Moonlight"
                        ? URL(fileURLWithPath: "/Applications/Moonlight.app")
                        : nil
                },
                appExists: { _ in false }
            )
        )
        #expect(
            AppState.macMoonlightAvailable(
                bundleURL: { _ in nil },
                appExists: { $0 == "/Applications/Moonlight.app" }
            )
        )
        let homeApp = MoonlightMacInstall.applicationsMoonlightURL().path
        #expect(
            AppState.macMoonlightAvailable(
                bundleURL: { _ in nil },
                appExists: { $0 == homeApp }
            )
        )
        #expect(
            AppState.macMoonlightAvailable(
                bundleURL: { _ in nil },
                appExists: { _ in false },
                binaryURL: URL(fileURLWithPath: "/opt/homebrew/bin/moonlight-qt")
            )
        )
    }

    @Test
    func viewDesktop_linux_hint_launches_stream_host_Desktop_and_does_not_add_a_pane() async {
        let state = makeAppState()
        let remote = Project(name: "box", path: "me@box.tailnet.ts.net:~/dev", sortOrder: 0)
        #expect(ProjectPath.remoteHost(from: remote.path) == "box.tailnet.ts.net")
        var launched: [DesktopLaunchAction] = []
        let beforeTabs = state.workspaces[remote.id]?.tabs.count ?? 0
        let result = await state.viewDesktop(
            project: remote,
            osHint: "linux",
            moonlightAvailable: true,
            perform: { action in
                launched.append(action)
                return true
            }
        )
        #expect(result == .opened)
        #expect(launched == [
            .moonlight(arguments: ["stream", "box.tailnet.ts.net", "Desktop"]),
        ])
        #expect(state.pendingViewDesktopError == nil)
        #expect((state.workspaces[remote.id]?.tabs.count ?? 0) == beforeTabs)
    }

    @Test
    func viewDesktop_macos_hint_opens_vnc() async throws {
        let state = makeAppState()
        let remote = Project(name: "mac", path: "dts-0.tailnet.ts.net:~", sortOrder: 0)
        var launched: [DesktopLaunchAction] = []
        let result = await state.viewDesktop(
            project: remote,
            osHint: "macOS",
            moonlightAvailable: true,
            perform: { action in
                launched.append(action)
                return true
            }
        )
        #expect(result == .opened)
        #expect(try launched == [.vnc(#require(URL(string: "vnc://dts-0.tailnet.ts.net")))])
    }

    @Test
    func viewDesktop_probe_macos_peer_opens_vnc_not_moonlight() async throws {
        let state = makeAppState()
        let remote = Project(name: "mac", path: "dts-0.tailnet.ts.net:~", sortOrder: 0)
        let device = TailscaleDevice(
            id: "n1",
            hostName: "dts-0",
            dnsName: "dts-0.tailnet.ts.net",
            os: "macOS",
            online: true,
            isSelf: false,
            tailscaleIPs: ["100.1.2.3"]
        )
        var launched: [DesktopLaunchAction] = []
        let result = await state.viewDesktop(
            project: remote,
            moonlightAvailable: true,
            probe: { .ready(devices: [device], selfHostName: "me") },
            perform: { action in
                launched.append(action)
                return true
            }
        )
        #expect(result == .opened)
        #expect(try launched == [.vnc(#require(URL(string: "vnc://dts-0.tailnet.ts.net")))])
    }

    @Test
    func viewDesktop_probe_linux_peer_launches_stream_host_Desktop() async {
        let state = makeAppState()
        let remote = Project(name: "box", path: "box.tailnet.ts.net:~", sortOrder: 0)
        let device = TailscaleDevice(
            id: "n2",
            hostName: "box",
            dnsName: "box.tailnet.ts.net",
            os: "linux",
            online: true,
            isSelf: false,
            tailscaleIPs: ["100.1.2.4"]
        )
        var launched: [DesktopLaunchAction] = []
        let result = await state.viewDesktop(
            project: remote,
            moonlightAvailable: true,
            probe: { .ready(devices: [device], selfHostName: "me") },
            perform: { action in
                launched.append(action)
                return true
            }
        )
        #expect(result == .opened)
        #expect(launched == [
            .moonlight(arguments: DesktopView.moonlightStreamArguments(host: "box.tailnet.ts.net")),
        ])
    }

    @Test
    func viewDesktop_installs_moonlight_then_launches() async {
        let state = makeAppState()
        let remote = Project(name: "box", path: "box.tailnet.ts.net:~", sortOrder: 0)
        var launched: [DesktopLaunchAction] = []
        var installed = 0
        let result = await state.viewDesktop(
            project: remote,
            osHint: "linux",
            moonlightAvailable: false,
            perform: { action in
                launched.append(action)
                return true
            },
            ensureMoonlight: {
                installed += 1
                return true
            }
        )
        #expect(result == .opened)
        #expect(installed == 1)
        #expect(launched == [
            .moonlight(arguments: DesktopView.moonlightStreamArguments(host: "box.tailnet.ts.net")),
        ])
    }

    @Test
    func viewDesktop_open_failure_is_not_the_missing_moonlight_dialog() async {
        let state = makeAppState()
        let remote = Project(name: "box", path: "box.tailnet.ts.net:~", sortOrder: 0)
        let result = await state.viewDesktop(
            project: remote,
            osHint: "linux",
            moonlightAvailable: true,
            perform: { _ in false }
        )
        #expect(result == .missing(DesktopView.moonlightLaunchFailedReason))
        #expect(state.pendingViewDesktopError == DesktopView.moonlightLaunchFailedReason)
        #expect(state.pendingViewDesktopError != DesktopView.moonlightMissingReason)
        #expect(!DesktopView.moonlightLaunchFailedReason.lowercased().contains("brew"))
        #expect(!DesktopView.moonlightLaunchFailedReason.contains("omarchy-install"))
        #expect(!DesktopView.moonlightLaunchFailedReason.contains("ssh"))
    }

    @Test
    func viewDesktop_macos_open_failure_is_host_not_sharing_not_missing_viewer() async {
        let state = makeAppState()
        let remote = Project(name: "mac", path: "dts-0.tailnet.ts.net:~", sortOrder: 0)
        let result = await state.viewDesktop(
            project: remote,
            osHint: "macOS",
            moonlightAvailable: true,
            perform: { _ in false }
        )
        #expect(result == .missing(DesktopView.vncHostNotSharingReason))
        #expect(state.pendingViewDesktopError == DesktopView.vncHostNotSharingReason)
        #expect(state.pendingViewDesktopError != DesktopView.vncMissingReason)
        #expect(!DesktopView.vncHostNotSharingReason.contains("ssh"))
        #expect(!DesktopView.vncHostNotSharingReason.contains("brew"))
    }

    @Test
    func viewDesktop_missing_moonlight_does_not_open_or_install() async {
        let state = makeAppState()
        let remote = Project(name: "box", path: "box.tailnet.ts.net:~", sortOrder: 0)
        var launched = 0
        let result = await state.viewDesktop(
            project: remote,
            osHint: "linux",
            moonlightAvailable: false,
            perform: { _ in
                launched += 1
                return true
            }
        )
        #expect(result == .missing(DesktopView.moonlightMissingReason))
        #expect(launched == 0)
        #expect(state.pendingViewDesktopError == DesktopView.moonlightMissingReason)
        #expect(!DesktopView.moonlightMissingReason.lowercased().contains("brew"))
        #expect(!DesktopView.moonlightMissingReason.contains("omarchy-install-service-sunshine"))
        #expect(!DesktopView.moonlightMissingReason.contains("ssh"))
    }

    @Test
    func viewDesktop_local_project_is_notRemote() async {
        let state = makeAppState()
        let local = Project(name: "local", path: "/tmp/proj", sortOrder: 0)
        var launched = 0
        let result = await state.viewDesktop(
            project: local,
            moonlightAvailable: true,
            perform: { _ in
                launched += 1
                return true
            }
        )
        #expect(result == .notRemote)
        #expect(launched == 0)
        #expect(state.pendingViewDesktopError == DesktopView.notRemoteReason)
    }

    @Test
    func viewDesktop_already_paired_only_streams() async {
        let state = makeAppState()
        let remote = Project(name: "box", path: "box.tailnet.ts.net:~", sortOrder: 0)
        var launched: [DesktopLaunchAction] = []
        var pairStarts = 0
        var pinSubmits = 0
        let result = await state.viewDesktop(
            project: remote,
            osHint: "linux",
            moonlightAvailable: true,
            perform: { action in
                launched.append(action)
                return true
            },
            pairing: .init(
                backgroundSSH: true,
                isPaired: { _ in true },
                startPair: { _, _ in
                    pairStarts += 1
                    return true
                },
                submitPin: { _, _, _ in
                    pinSubmits += 1
                    return true
                }
            )
        )
        #expect(result == .opened)
        #expect(pairStarts == 0)
        #expect(pinSubmits == 0)
        #expect(launched == [
            .moonlight(arguments: DesktopView.moonlightStreamArguments(host: "box.tailnet.ts.net")),
        ])
    }

    @Test
    func viewDesktop_unpaired_pairs_then_streams() async throws {
        let state = makeAppState()
        let remote = Project(name: "box", path: "me@box.tailnet.ts.net:~/dev", sortOrder: 0)
        var launched: [DesktopLaunchAction] = []
        var pairHost: String?
        var pairPin: String?
        var pinProject: UUID?
        let result = await state.viewDesktop(
            project: remote,
            osHint: "linux",
            moonlightAvailable: true,
            perform: { action in
                launched.append(action)
                return true
            },
            pairing: .init(
                backgroundSSH: true,
                isPaired: { _ in false },
                startPair: { host, pin in
                    pairHost = host
                    pairPin = pin
                    return true
                },
                submitPin: { project, pin, _ in
                    pinProject = project.id
                    #expect(DesktopView.isValidPairingPin(pin))
                    #expect(pin == pairPin)
                    return true
                }
            )
        )
        #expect(result == .opened)
        #expect(pairHost == "box.tailnet.ts.net")
        #expect(DesktopView.isValidPairingPin(pairPin ?? ""))
        #expect(pinProject == remote.id)
        #expect(launched == [
            .moonlight(arguments: DesktopView.moonlightStreamArguments(host: "box.tailnet.ts.net")),
        ])
        let parsed = try #require(ProjectPath.parse(remote.path))
        let argv = RemoteSpawn.sunshinePairArgv(
            remote: parsed,
            pin: pairPin ?? "0000",
            clientName: "Mac"
        )
        #expect(argv?.contains("BatchMode=yes") == true)
        #expect(argv?.joined(separator: " ").contains("pacman") == false)
    }

    @Test
    func viewDesktop_skips_pair_when_background_ssh_is_off() async {
        let state = makeAppState()
        let remote = Project(name: "box", path: "box.tailnet.ts.net:~", sortOrder: 0)
        var pairStarts = 0
        let result = await state.viewDesktop(
            project: remote,
            osHint: "linux",
            moonlightAvailable: true,
            perform: { _ in true },
            pairing: .init(
                backgroundSSH: false,
                isPaired: { _ in false },
                startPair: { _, _ in
                    pairStarts += 1
                    return true
                },
                submitPin: { _, _, _ in true }
            )
        )
        #expect(result == .opened)
        #expect(pairStarts == 0)
    }

    @Test
    func openLocalListenerInBrowser_missing_id_is_notFound() {
        let state = makeAppState()
        #expect(state.openLocalListenerInBrowser(id: "missing", openURL: { _ in true }) == .notFound)
    }

    @Test
    func openLocalListenerInBrowser_passes_displayURL() {
        let state = makeAppState()
        let row = listenerRow(id: "1:3000", displayURL: "http://127.0.0.1:3000")
        state.applyLocalListenerSnapshot(.ready([row]))
        var opened: URL?
        let result = state.openLocalListenerInBrowser(id: row.id, openURL: { url in
            opened = url
            return true
        })
        #expect(result == .opened)
        #expect(opened?.absoluteString == "http://127.0.0.1:3000")
    }

    @Test
    func openLocalListenerInBrowser_openURL_false_is_failed() {
        let state = makeAppState()
        let row = listenerRow(id: "1:3000")
        state.applyLocalListenerSnapshot(.ready([row]))
        #expect(state.openLocalListenerInBrowser(id: row.id, openURL: { _ in false }) == .failed)
    }

    @Test
    func openLocalListenerInBrowser_rejects_non_loopback_displayURL() {
        let state = makeAppState()
        let row = listenerRow(id: "1:80", displayURL: "http://0.0.0.0:80")
        state.applyLocalListenerSnapshot(.ready([row]))
        var called = false
        let result = state.openLocalListenerInBrowser(id: row.id, openURL: { _ in
            called = true
            return true
        })
        #expect(result == .failed)
        #expect(!called)
    }

    @Test
    func showLocalListenerInApp_missing_id_is_none() {
        let state = makeAppState()
        #expect(state.showLocalListenerInApp(id: "missing", projects: []) == .none)
    }

    @Test
    func showLocalListenerInApp_local_projectID_selects_without_touching_panes() throws {
        let state = makeAppState()
        let first = seedProject(state, name: "alpha", path: "/tmp/alpha")
        let second = Project(name: "beta", path: "/tmp/beta", sortOrder: 1)
        state.selectProject(second)
        let firstPane = try #require(state.workspaces[first.id]?.activeTab?.focusedPaneID)
        let row = listenerRow(id: "9:3000", pid: 9, projectID: first.id)
        state.applyLocalListenerSnapshot(.ready([row]))

        let result = state.showLocalListenerInApp(
            id: row.id,
            projects: [first, second],
            resolvedForegroundPID: { _ in nil }
        )
        #expect(result == .selectedProject)
        #expect(state.activeProjectID == first.id)
        #expect(state.workspaces[first.id]?.activeTab?.focusedPaneID == firstPane)
        #expect(state.workspaces[first.id]?.activeTab?.splitRoot.allPanes().count == 1)
    }

    @Test
    func showLocalListenerInApp_pane_pid_match_focuses_pane() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let pane = try #require(tab.focusedPane)
        let row = listenerRow(id: "42:3000", pid: 4242, projectID: nil)
        state.applyLocalListenerSnapshot(.ready([row]))

        let result = state.showLocalListenerInApp(
            id: row.id,
            projects: [project],
            resolvedForegroundPID: { $0.id == pane.id ? 4242 : nil }
        )
        #expect(result == .focusedPane)
        #expect(state.activeProjectID == project.id)
        #expect(tab.focusedPaneID == pane.id)
    }

    @Test
    func showLocalListenerInApp_pane_process_group_match_focuses_pane() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let pane = try #require(tab.focusedPane)
        let row = listenerRow(id: "200:5173", pid: 200, projectID: nil)
        state.applyLocalListenerSnapshot(.ready([row]))

        let result = state.showLocalListenerInApp(
            id: row.id,
            projects: [project],
            resolvedForegroundPID: { $0.id == pane.id ? 100 : nil },
            processGroupID: { $0 == 200 ? 100 : nil }
        )
        #expect(result == .focusedPane)
        #expect(state.activeProjectID == project.id)
        #expect(tab.focusedPaneID == pane.id)
    }

    @Test
    func showLocalListenerInApp_unrelated_process_group_falls_back_to_project() throws {
        let state = makeAppState()
        let project = seedProject(state)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        let pane = try #require(tab.focusedPane)
        let row = listenerRow(id: "200:5173", pid: 200, projectID: project.id)
        state.applyLocalListenerSnapshot(.ready([row]))

        let result = state.showLocalListenerInApp(
            id: row.id,
            projects: [project],
            resolvedForegroundPID: { $0.id == pane.id ? 100 : nil },
            processGroupID: { _ in 300 }
        )
        #expect(result == .selectedProject)
        #expect(state.activeProjectID == project.id)
        #expect(tab.focusedPaneID == pane.id)
    }

    @Test
    func killLocalListeners_drops_signaled_rows() async {
        let state = makeAppState()
        let project = seedProject(state)
        let pid = livePidForKillTests()
        let started = ProcessInspector.startDate(pid: pid)
        state.applyLocalListenerSnapshot(.ready([
            listenerRow(id: "\(pid):5173", pid: pid, port: 5173, startDate: started),
            listenerRow(id: "99:3000", pid: 99, port: 3000),
        ]))
        await state.killLocalListeners(ids: ["\(pid):5173"], projects: [project], signal: { _ in 0 })
        #expect(!state.localListenerRows.contains { $0.pid == pid })
    }

    @Test
    func showLocalListenerInApp_remote_projectID_is_none() {
        let state = makeAppState()
        let remote = Project(name: "box", path: "host:/srv/app", sortOrder: 0)
        let row = listenerRow(id: "3:8080", pid: 3, projectID: remote.id)
        state.applyLocalListenerSnapshot(.ready([row]))
        let result = state.showLocalListenerInApp(
            id: row.id,
            projects: [remote],
            resolvedForegroundPID: { _ in nil }
        )
        #expect(result == .none)
        #expect(state.activeProjectID != remote.id)
    }

    // MARK: - Inventory kill (POR-445)

    @Test
    func killInventorySessions_unattached_records_killSession() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let project = seedProject(state)
        let pane = try #require(state.workspaces[project.id]?.activeTab?.splitRoot.allPanes().first)
        let unattached = "futuraterm-proj-deaddeaddead"
        state.applySessionInventorySnapshot(
            (
                entries: [
                    .init(name: pane.sessionName, clients: 1),
                    .init(name: unattached, clients: 0),
                ],
                leaders: [:]
            ),
            projects: [project],
            inspect: { _ in (nil, nil) }
        )

        await state.killInventorySessions([unattached], projects: [project])

        await killed.settle(expecting: 1)
        #expect(await killed.names == [unattached])
        #expect(state.workspaces[project.id]?.activeTab?.splitRoot.findPane(id: pane.id) != nil)
    }

    @Test
    func killInventorySessions_attached_closes_pane() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let project = seedProject(state)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: project.id)
        let target = try #require(tab.focusedPane)
        state.applySessionInventorySnapshot(
            (
                entries: tab.splitRoot.allPanes().map { .init(name: $0.sessionName, clients: 1) },
                leaders: [:]
            ),
            projects: [project],
            inspect: { _ in (nil, nil) }
        )

        await state.killInventorySessions([target.sessionName], projects: [project])

        #expect(tab.splitRoot.findPane(id: target.id) == nil)
        await killed.settle(expecting: 1)
        #expect(await killed.names.contains(target.sessionName))
    }

    @Test
    func killInventorySessions_attached_awaits_kill_before_returning() async throws {
        actor Gate {
            var opened = false
            var waiters: [CheckedContinuation<Void, Never>] = []
            func open() {
                opened = true
                for waiter in waiters {
                    waiter.resume()
                }
                waiters.removeAll()
            }

            func wait() async {
                if opened { return }
                await withCheckedContinuation { waiters.append($0) }
            }
        }
        let gate = Gate()
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { name in
                await gate.wait()
                await killed.append(name)
            },
            killRemoteSession: { _, _, _ in },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { [] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [], leaders: [:]) }
        )
        let project = seedProject(state)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: project.id)
        let target = try #require(tab.focusedPane)
        state.applySessionInventorySnapshot(
            (
                entries: tab.splitRoot.allPanes().map { .init(name: $0.sessionName, clients: 1) },
                leaders: [:]
            ),
            projects: [project],
            inspect: { _ in (nil, nil) }
        )

        let task = Task {
            await state.killInventorySessions([target.sessionName], projects: [project])
        }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await killed.names.isEmpty)
        await gate.open()
        await task.value
        #expect(await killed.names.contains(target.sessionName))
        #expect(tab.splitRoot.findPane(id: target.id) == nil)
    }

    @Test
    func killInventorySessions_empty_and_unknown_are_noop() async {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let project = seedProject(state)
        state.applySessionInventorySnapshot(
            (entries: [.init(name: "futuraterm-proj-aaaaaaaaaaaa", clients: 0)], leaders: [:]),
            projects: [project],
            inspect: { _ in (nil, nil) }
        )

        await state.killInventorySessions([], projects: [project])
        await state.killInventorySessions(["does-not-exist"], projects: [project])
        await killed.settleExpectingNone()
        #expect(await killed.names.isEmpty)
    }

    @Test
    func killInventorySessions_mixed_uses_both_paths() async throws {
        let killed = KilledSessions()
        let state = makeAppState()
        state.zmx = recordingZmx(into: killed)
        let project = seedProject(state)
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        state.splitPane(direction: .horizontal, projectID: project.id)
        let attached = try #require(tab.focusedPane)
        let unattached = "other-session"
        let remaining = try #require(tab.splitRoot.allPanes().first { $0.id != attached.id })
        state.applySessionInventorySnapshot(
            (
                entries: [
                    .init(name: attached.sessionName, clients: 1),
                    .init(name: remaining.sessionName, clients: 1),
                    .init(name: unattached, clients: 0),
                ],
                leaders: [:]
            ),
            projects: [project],
            inspect: { _ in (nil, nil) }
        )

        await state.killInventorySessions([attached.sessionName, unattached], projects: [project])

        #expect(tab.splitRoot.findPane(id: attached.id) == nil)
        #expect(tab.splitRoot.findPane(id: remaining.id) != nil)
        await killed.settle(expecting: 2)
        #expect(await killed.names.contains(unattached))
        #expect(await killed.names.contains(attached.sessionName))

        state.applySessionInventorySnapshot(
            (
                entries: [
                    .init(name: remaining.sessionName, clients: 1),
                    .init(name: unattached, clients: 0),
                ],
                leaders: [:]
            ),
            projects: [project],
            inspect: { _ in (nil, nil) }
        )
        let remainingRow = try #require(
            state.sessionInventoryRows.first { $0.name == remaining.sessionName }
        )
        #expect(remainingRow.attachment == .attached)
        #expect(remainingRow.claim?.projectID == project.id)
    }

    // MARK: - Open inventory session (POR-446)

    private func stubInventory(
        _ state: AppState,
        projects: [Project],
        entries: [ZmxSessionListParser.Entry]
    ) {
        state.applySessionInventorySnapshot(
            (entries: entries, leaders: [:]),
            projects: projects,
            inspect: { _ in (nil, nil) }
        )
    }

    @Test
    func openInventorySession_unattached_persists_name_and_nil_command() throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        let workspace = try #require(state.workspaces[project.id])
        let originalCount = workspace.tabs.count
        let name = grokSessionName()
        stubInventory(state, projects: [project], entries: [.init(name: name, clients: 0)])

        let result = state.openInventorySession(name, projects: [project])

        #expect(result == .attached)
        #expect(workspace.tabs.count == originalCount + 1)
        let pane = try #require(workspace.tabs.last?.splitRoot.allPanes().first)
        #expect(pane.sessionName == name)
        #expect(pane.command == nil)
        #expect(workspace.activeTabID == workspace.tabs.last?.id)
    }

    @Test
    func openInventorySession_attached_focuses_without_new_tab() throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/tmp/kectil")
        let workspace = try #require(state.workspaces[project.id])
        _ = workspace.createTab(projectPath: project.path)
        let first = try #require(workspace.tabs.first)
        let pane = try #require(first.splitRoot.allPanes().first)
        try workspace.selectTab(#require(workspace.tabs.last?.id))
        stubInventory(
            state,
            projects: [project],
            entries: workspace.tabs.flatMap { $0.splitRoot.allPanes() }.map { .init(name: $0.sessionName, clients: 1) }
        )
        let count = workspace.tabs.count

        let result = state.openInventorySession(pane.sessionName, projects: [project])

        #expect(result == .focused)
        #expect(workspace.tabs.count == count)
        #expect(workspace.activeTabID == first.id)
        #expect(first.focusedPaneID == pane.id)
        #expect(pane.command == nil)
    }

    @Test
    func openInventorySession_second_open_does_not_duplicate_pane() throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        let workspace = try #require(state.workspaces[project.id])
        let name = grokSessionName()
        stubInventory(state, projects: [project], entries: [.init(name: name, clients: 0)])

        #expect(state.openInventorySession(name, projects: [project]) == .attached)
        let count = workspace.tabs.count
        let result = state.openInventorySession(name, projects: [project])

        #expect(result == .focused)
        #expect(workspace.tabs.count == count)
        let panes = workspace.tabs.flatMap { $0.splitRoot.allPanes() }.filter { $0.sessionName == name }
        #expect(panes.count == 1)
        #expect(panes.first?.command == nil)
    }

    @Test
    func openInventorySession_needsLocalProject_when_pinned_unmatched() throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/tmp/kectil")
        let tab = try #require(state.workspaces[project.id]?.activeTab)
        state.pinTab(tab.id, fromProject: project.id)
        let name = "futuraterm-elsewhere-aaaaaaaaaaaa"
        stubInventory(state, projects: [project], entries: [.init(name: name, clients: 0)])

        let result = state.openInventorySession(name, projects: [project])

        #expect(result == .needsLocalProject)
        #expect(state.pinnedWorkspace?.tabs.count == 1)
    }

    @Test
    func openInventorySession_foreign_name_preserved_on_active_local() throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/tmp/kectil")
        let workspace = try #require(state.workspaces[project.id])
        let name = "tmux-foreign-session"
        stubInventory(state, projects: [project], entries: [.init(name: name, clients: 0)])

        #expect(state.openInventorySession(name, projects: [project]) == .attached)
        let pane = try #require(workspace.tabs.last?.splitRoot.allPanes().first)
        #expect(pane.sessionName == name)
        #expect(pane.command == nil)
    }

    @Test
    func openInventorySession_notFound() {
        let state = makeAppState()
        let project = seedProject(state)
        stubInventory(state, projects: [project], entries: [])
        #expect(state.openInventorySession("missing", projects: [project]) == .notFound)
    }

    // MARK: - Adopt unclaimed grok sessions (POR-372)

    private func grokSessionName(projectName: String = "Kectil") -> String {
        "futuraterm-\(ZmxSessionName.slug(projectName))-aaaaaaaaaaaa"
    }

    private func grokCandidate(
        projectName: String = "Kectil",
        cwd: String? = nil
    ) -> GrokSessionAdoption.Candidate {
        let name = grokSessionName(projectName: projectName)
        return GrokSessionAdoption.Candidate(
            sessionName: name,
            slug: ZmxSessionName.slug(fromName: name) ?? "",
            cwd: cwd
        )
    }

    private func recordingReapZmx(
        entries: [ZmxSessionListParser.Entry],
        into killed: KilledSessions
    ) -> ZmxClient {
        ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { name in await killed.append(name) },
            killRemoteSession: { _, _, _ in },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { entries },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: entries, leaders: [:]) }
        )
    }

    @Test
    func adoptUnclaimedGrokSessions_appends_tab_with_persisted_name_and_nil_command() async throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        let workspace = try #require(state.workspaces[project.id])
        let originalTabID = try #require(workspace.activeTabID)
        let originalCount = workspace.tabs.count
        let candidate = grokCandidate()

        await state.adoptUnclaimedGrokSessions(projects: [project], candidates: [candidate])

        #expect(workspace.tabs.count == originalCount + 1)
        #expect(workspace.activeTabID == originalTabID)
        let adopted = try #require(workspace.tabs.last)
        #expect(adopted.id != originalTabID)
        let pane = try #require(adopted.splitRoot.allPanes().first)
        #expect(pane.sessionName == candidate.sessionName)
        #expect(pane.command == nil)
        #expect(pane.projectID == project.id)
        #expect(pane.projectPath == project.path)
    }

    @Test
    func adoptUnclaimedGrokSessions_second_pass_is_noop() async throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        let workspace = try #require(state.workspaces[project.id])
        let candidate = grokCandidate()

        await state.adoptUnclaimedGrokSessions(projects: [project], candidates: [candidate])
        let count = workspace.tabs.count
        await state.adoptUnclaimedGrokSessions(projects: [project], candidates: [candidate])

        #expect(workspace.tabs.count == count)
        let grokPanes = workspace.tabs.flatMap { $0.splitRoot.allPanes() }
            .filter { $0.sessionName == candidate.sessionName }
        #expect(grokPanes.count == 1)
    }

    @Test
    func adoptUnclaimedGrokSessions_skips_already_claimed_name() async throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        let workspace = try #require(state.workspaces[project.id])
        let existing = try #require(workspace.tabs.first?.splitRoot.allPanes().first?.sessionName)
        let count = workspace.tabs.count
        let claimed = GrokSessionAdoption.Candidate(
            sessionName: existing,
            slug: ZmxSessionName.slug(fromName: existing) ?? "kectil",
            cwd: nil
        )

        await state.adoptUnclaimedGrokSessions(projects: [project], candidates: [claimed])

        #expect(workspace.tabs.count == count)
    }

    @Test
    func adoptUnclaimedGrokSessions_skips_name_claimed_in_another_project() async throws {
        let state = makeAppState()
        let owner = seedProject(state, name: "Owner", path: "/tmp/owner")
        let kectil = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        let ownerWorkspace = try #require(state.workspaces[owner.id])
        let claimedName = try #require(ownerWorkspace.tabs.first?.splitRoot.allPanes().first?.sessionName)
        let kectilCount = try #require(state.workspaces[kectil.id]).tabs.count
        let stolen = GrokSessionAdoption.Candidate(
            sessionName: claimedName,
            slug: "kectil",
            cwd: kectil.path
        )

        await state.adoptUnclaimedGrokSessions(projects: [owner, kectil], candidates: [stolen])

        #expect(state.workspaces[kectil.id]?.tabs.count == kectilCount)
        #expect(state.workspaces[owner.id]?.tabs.count == 1)
    }

    @Test
    func adoptUnclaimedGrokSessions_does_not_create_project_for_unmatched() async throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        let workspace = try #require(state.workspaces[project.id])
        let count = workspace.tabs.count
        let foreign = GrokSessionAdoption.Candidate(
            sessionName: "futuraterm-elsewhere-aaaaaaaaaaaa",
            slug: "elsewhere",
            cwd: "/tmp/nope"
        )

        await state.adoptUnclaimedGrokSessions(projects: [project], candidates: [foreign])

        #expect(workspace.tabs.count == count)
        #expect(state.workspaces.count == 1)
    }

    @Test
    func adoptUnclaimedGrokSessions_then_createTab_still_types_grok() async throws {
        let prior = Preferences.shared.startGrokInNewTabs
        defer { Preferences.shared.startGrokInNewTabs = prior }
        Preferences.shared.startGrokInNewTabs = true

        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        await state.adoptUnclaimedGrokSessions(projects: [project], candidates: [grokCandidate()])

        let tabID = try #require(state.createTab(projectID: project.id, projectPath: project.path))
        let workspace = try #require(state.workspaces[project.id])
        #expect(workspace.tabs.last?.id == tabID)
        let newPane = try #require(workspace.tabs.last?.splitRoot.allPanes().first)
        #expect(newPane.command == "grok")
        #expect(newPane.sessionName != grokCandidate().sessionName)
    }

    @Test
    func adopt_then_reap_spares_grok_and_kills_unclaimed_idle() async {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        let grokName = grokSessionName()
        let idleName = "futuraterm-idle-bbbbbbbbbbbb"
        let killed = KilledSessions()
        state.zmx = recordingReapZmx(
            entries: [
                .init(name: grokName, clients: 0),
                .init(name: idleName, clients: 0),
            ],
            into: killed
        )

        await state.adoptUnclaimedGrokSessions(
            projects: [project],
            candidates: [grokCandidate()]
        )
        await state.materializePinnedAdoptGrokAndReap(projects: [project])

        await killed.settle(expecting: 1)
        #expect(await killed.names == [idleName])
        let paneNames = state.workspaces[project.id]?.tabs
            .flatMap { $0.splitRoot.allPanes() }
            .map(\.sessionName) ?? []
        #expect(paneNames.contains(grokName))
        let grokPane = state.workspaces[project.id]?.tabs
            .flatMap { $0.splitRoot.allPanes() }
            .first { $0.sessionName == grokName }
        #expect(grokPane?.command == nil)
    }

    @Test
    func adoptUnclaimedGrokSessions_adds_separate_tab_on_fresh_workspace() async throws {
        let state = makeAppState()
        let project = Project(name: "Kectil", path: "/Users/x/code/kectil", sortOrder: 0)
        let candidate = grokCandidate()

        await state.adoptUnclaimedGrokSessions(projects: [project], candidates: [candidate])

        let workspace = try #require(state.workspaces[project.id])
        #expect(workspace.tabs.count == 2)
        let defaultPane = try #require(workspace.tabs[0].splitRoot.allPanes().first)
        let adoptedPane = try #require(workspace.tabs[1].splitRoot.allPanes().first)
        #expect(defaultPane.sessionName != candidate.sessionName)
        #expect(adoptedPane.sessionName == candidate.sessionName)
        #expect(adoptedPane.command == nil)
        #expect(workspace.activeTabID == workspace.tabs[0].id)
    }

    @Test
    func adoptThenSweep_uses_projects_remembered_from_select() async throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        let workspace = try #require(state.workspaces[project.id])
        let originalCount = workspace.tabs.count

        await state.adoptUnclaimedGrokSessionsThenSweep(project: project, candidates: [grokCandidate()])

        #expect(workspace.tabs.count == originalCount + 1)
        let pane = try #require(workspace.tabs.last?.splitRoot.allPanes().first)
        #expect(pane.sessionName == grokCandidate().sessionName)
        #expect(pane.command == nil)
    }

    @Test
    func adoptUnclaimedGrokSessions_live_gatherer_is_noop_in_tests() async throws {
        let state = makeAppState()
        let project = seedProject(state, name: "Kectil", path: "/Users/x/code/kectil")
        let workspace = try #require(state.workspaces[project.id])
        let count = workspace.tabs.count
        state.zmx = recordingReapZmx(
            entries: [.init(name: grokSessionName(), clients: 0)],
            into: KilledSessions()
        )

        await state.adoptUnclaimedGrokSessions(projects: [project])

        #expect(workspace.tabs.count == count)
    }
}

/// Actor recording killed session names across the fire-and-forget kill tasks.
private actor KilledSessions {
    private(set) var names: Set<String> = []
    func append(_ name: String) {
        names.insert(name)
    }

    /// Wait until at least `count` distinct names have been recorded (or a
    /// generous timeout elapses). Waiting for the EXPECTED count — not merely
    /// "anything arrived" — means a slow second kill can't make a positive
    /// assertion pass before all kills have landed.
    func settle(expecting count: Int) async {
        for _ in 0 ..< 200 where names.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// For negative assertions ("nothing should have been killed"): wait a
    /// deterministic window so a late kill would have shown up, then the caller
    /// asserts emptiness. Named distinctly so its intent (and its inherent
    /// fixed-wait limitation) is explicit at the call site.
    func settleExpectingNone() async {
        try? await Task.sleep(for: .milliseconds(200))
    }
}
