import Foundation
@testable import FuturaTerm
import Testing

@MainActor
struct FolderExecutionTests {
    private func makeStore() -> ProjectStore {
        let projects = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-folder-exec-\(UUID().uuidString).json")
        let groups = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-folder-exec-groups-\(UUID().uuidString).json")
        return ProjectStore(fileURL: projects, groupsFileURL: groups)
    }

    private func workspace(
        for project: Project,
        tabStates: TerminalExecutionState...
    ) -> Workspace {
        let tabs = tabStates.map { state -> TerminalTab in
            let tab = TerminalTab(projectPath: project.path, projectID: project.id)
            tab.splitRoot.allPanes().first?.executionState = state
            return tab
        }
        return Workspace(
            projectID: project.id,
            tabs: tabs,
            activeTabID: tabs.first?.id
        )
    }

    @Test
    func combined_prefers_running_then_done_then_idle() {
        #expect(TerminalExecutionState.combined([.running, .done]) == .running)
        #expect(TerminalExecutionState.combined([.done, .idle, .running]) == .running)
        #expect(TerminalExecutionState.combined([.done]) == .done)
        #expect(TerminalExecutionState.combined([.idle, .done, .idle]) == .done)
        #expect(TerminalExecutionState.combined([.idle, .idle]) == .idle)
        #expect(TerminalExecutionState.combined([]) == .idle)
    }

    @Test
    func folderExecutionState_bubbles_running_to_ancestors() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let team = try #require(store.createGroup(name: "Team", parentID: kectil.id))
        let home = try #require(store.createGroup(name: "Home"))
        let teamProj = store.create(name: "team", path: "/tmp/team")
        let homeProj = store.create(name: "home", path: "/tmp/home")
        store.setGroup(projectID: teamProj.id, groupID: team.id)
        store.setGroup(projectID: homeProj.id, groupID: home.id)

        let workspaces: [UUID: Workspace] = [
            teamProj.id: workspace(for: teamProj, tabStates: .running),
            homeProj.id: workspace(for: homeProj, tabStates: .idle),
        ]

        #expect(store.folderExecutionState(groupID: team.id, workspaces: workspaces) == .running)
        #expect(store.folderExecutionState(groupID: kectil.id, workspaces: workspaces) == .running)
        #expect(store.folderExecutionState(groupID: clients.id, workspaces: workspaces) == .running)
        #expect(store.folderExecutionState(groupID: home.id, workspaces: workspaces) == .idle)
        #expect(store.folderExecutionState(groupID: UUID(), workspaces: workspaces) == .idle)
    }

    @Test
    func folderExecutionState_done_nested_plus_idle_does_not_outrank_parent_done() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let nested = store.create(name: "nested", path: "/tmp/nested")
        let sibling = store.create(name: "sibling", path: "/tmp/sibling")
        store.setGroup(projectID: nested.id, groupID: kectil.id)
        store.setGroup(projectID: sibling.id, groupID: clients.id)

        let workspaces: [UUID: Workspace] = [
            nested.id: workspace(for: nested, tabStates: .idle),
            sibling.id: workspace(for: sibling, tabStates: .done),
        ]

        #expect(store.folderExecutionState(groupID: kectil.id, workspaces: workspaces) == .idle)
        #expect(store.folderExecutionState(groupID: clients.id, workspaces: workspaces) == .done)
    }

    @Test
    func folderExecutionState_ignores_ungrouped_busy_project() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let grouped = store.create(name: "grouped", path: "/tmp/grouped")
        let ungrouped = store.create(name: "ungrouped", path: "/tmp/ungrouped")
        store.setGroup(projectID: grouped.id, groupID: clients.id)

        let workspaces: [UUID: Workspace] = [
            grouped.id: workspace(for: grouped, tabStates: .idle),
            ungrouped.id: workspace(for: ungrouped, tabStates: .running),
        ]

        #expect(store.folderExecutionState(groupID: clients.id, workspaces: workspaces) == .idle)
    }

    @Test
    func folderExecutionState_missing_workspace_is_idle() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let project = store.create(name: "lazy", path: "/tmp/lazy")
        store.setGroup(projectID: project.id, groupID: clients.id)
        #expect(store.folderExecutionState(groupID: clients.id, workspaces: [:]) == .idle)
    }
}
