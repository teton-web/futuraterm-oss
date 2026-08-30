import Foundation
@testable import FuturaTerm
import Testing

@MainActor
struct ProjectStoreTests {
    private func makeStore(fileURL: URL? = nil, groupsFileURL: URL? = nil) -> ProjectStore {
        let projects = fileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-tests-\(UUID().uuidString).json")
        let groups = groupsFileURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-groups-tests-\(UUID().uuidString).json")
        return ProjectStore(fileURL: projects, groupsFileURL: groups)
    }

    /// `ancestorFolderIDs` must not hang if load left a repaired (or residual) cycle.
    private func assertAncestorWalkIsFinite(_ store: ProjectStore, _ id: UUID) {
        let ids = store.ancestorFolderIDs(id)
        #expect(ids.first == id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count <= store.groups.count)
    }

    /// Same sibling index `folderMenu` uses (`childGroups(in: resolvedParentID)`).
    private func folderMenuSiblingIndex(_ store: ProjectStore, _ group: ProjectGroup) -> (index: Int, count: Int) {
        let parentID = store.resolvedParentID(group.parentID)
        let siblings = store.childGroups(in: parentID)
        let index = siblings.firstIndex(where: { $0.id == group.id }) ?? 0
        return (index, siblings.count)
    }

    @Test
    func find_or_create_reuses_canonical_local_path() {
        let store = makeStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-\(UUID().uuidString)", isDirectory: true)
            .path
        let existing = Project(name: "existing", path: base + "/./", sortOrder: 0)
        store.add(existing)

        let project = store.findOrCreate(name: "duplicate", path: base)

        #expect(project.id == existing.id)
        #expect(project.name == "existing")
        #expect(store.projects.count == 1)
    }

    @Test
    func create_always_appends_even_for_a_matching_path() {
        // Removing the one-project-per-directory constraint: `create` never
        // dedups, so the same directory can back several independent projects.
        let store = makeStore()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-\(UUID().uuidString)", isDirectory: true)
            .path
        let first = store.create(name: "one", path: base)
        let second = store.create(name: "two", path: base + "/./")

        #expect(first.id != second.id)
        #expect(store.projects.count == 2)
        // Both normalize to the same canonical path — distinct projects, one dir.
        #expect(store.projects.map(\.path) == [first.path, first.path])
        #expect(store.projects.map(\.name) == ["one", "two"])
    }

    @Test
    func find_or_create_reuses_matching_remote_path() {
        let store = makeStore()
        let existing = Project(name: "api", path: "devbox:~/dev/api", sortOrder: 0)
        store.add(existing)

        let project = store.findOrCreate(
            name: "duplicate",
            path: "devbox:~/dev/api",
            zmxPath: "~/bin/zmx"
        )

        #expect(project.id == existing.id)
        #expect(project.zmxPath == nil)
        #expect(store.projects.count == 1)
    }

    // MARK: - Mutators

    @Test
    func remove_drops_the_project() {
        let store = makeStore()
        let a = Project(name: "a", path: "/tmp/a", sortOrder: 0)
        let b = Project(name: "b", path: "/tmp/b", sortOrder: 1)
        store.add(a)
        store.add(b)
        store.remove(id: a.id)
        #expect(store.projects.map(\.id) == [b.id])
    }

    @Test
    func rename_changes_name_but_not_identity_or_path() {
        let store = makeStore()
        let p = Project(name: "old", path: "/tmp/x", sortOrder: 0)
        store.add(p)
        store.rename(id: p.id, to: "new")
        let updated = store.projects.first { $0.id == p.id }
        #expect(updated?.name == "new")
        #expect(updated?.path == "/tmp/x")
    }

    @Test
    func setPath_updates_the_path() {
        let store = makeStore()
        let p = Project(name: "x", path: "/tmp/before", sortOrder: 0)
        store.add(p)
        store.setPath(id: p.id, to: "/tmp/after")
        #expect(store.projects.first { $0.id == p.id }?.path == "/tmp/after")
    }

    @Test
    func reorder_reindexes_sortOrder() {
        let store = makeStore()
        let a = Project(name: "a", path: "/tmp/a", sortOrder: 0)
        let b = Project(name: "b", path: "/tmp/b", sortOrder: 1)
        let c = Project(name: "c", path: "/tmp/c", sortOrder: 2)
        store.add(a)
        store.add(b)
        store.add(c)
        // Move the last (c) to the front.
        store.reorder(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.projects.map(\.name) == ["c", "a", "b"])
        #expect(store.projects.map(\.sortOrder) == [0, 1, 2])
    }

    // MARK: - Path normalization (a stored trailing slash reaches $PWD verbatim: fatal under nushell — the pane fails to spawn — and blanks zsh's `%c` prompt)

    @Test
    func add_strips_trailing_slash_from_local_path() {
        let store = makeStore()
        store.add(Project(name: "junk", path: "/tmp/junk/", sortOrder: 0))
        #expect(store.projects.first?.path == "/tmp/junk")
    }

    @Test
    func add_leaves_remote_path_verbatim() {
        let store = makeStore()
        store.add(Project(name: "api", path: "devbox:~/dev/api/", sortOrder: 0))
        #expect(store.projects.first?.path == "devbox:~/dev/api/")
    }

    @Test
    func setPath_normalizes_the_new_path() {
        let store = makeStore()
        let p = Project(name: "x", path: "/tmp/before", sortOrder: 0)
        store.add(p)
        store.setPath(id: p.id, to: "/tmp/after/")
        #expect(store.projects.first { $0.id == p.id }?.path == "/tmp/after")
    }

    @Test
    func load_migrates_paths_stored_with_trailing_slashes() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-migrate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        // Write the legacy on-disk form directly — the store's own mutators
        // normalize now, so a pre-fix file has to be crafted by hand.
        let legacy = Project(name: "legacy", path: "/tmp/legacy/", sortOrder: 0)
        try JSONEncoder().encode([legacy]).write(to: fileURL)

        let store = makeStore(fileURL: fileURL)
        #expect(store.projects.first?.path == "/tmp/legacy")
    }

    // MARK: - On-disk round-trip

    @Test
    func round_trips_through_the_file() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let writer = makeStore(fileURL: fileURL)
        let a = Project(name: "alpha", path: "/tmp/alpha", sortOrder: 0)
        let b = Project(name: "beta", path: "/tmp/beta", sortOrder: 1)
        writer.add(a)
        writer.add(b)

        // A fresh store reading the same file sees the persisted contents.
        let reader = makeStore(fileURL: fileURL)
        #expect(reader.projects.map(\.name) == ["alpha", "beta"])
        #expect(reader.projects.map(\.path) == ["/tmp/alpha", "/tmp/beta"])
        #expect(reader.projects.map(\.id) == [a.id, b.id])
    }

    // MARK: - Corrupt-file save refusal (data-loss regression, #4.6)

    @Test
    func decode_missing_groupID_is_nil() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-nogroup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","name":"alpha","path":"/tmp/alpha","sortOrder":0,"createdAt":0}]
        """
        try Data(json.utf8).write(to: fileURL)

        let store = makeStore(fileURL: fileURL)
        #expect(store.projects.count == 1)
        #expect(store.projects.first?.groupID == nil)
        #expect(store.projects.first?.name == "alpha")
    }

    @Test
    func createGroup_setGroup_round_trips_membership() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-groups-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-groups-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        let writer = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        let p = writer.create(name: "alpha", path: "/tmp/alpha")
        let group = writer.createGroup(name: "Work")
        #expect(group != nil)
        writer.setGroup(projectID: p.id, groupID: group?.id)

        let reader = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        #expect(reader.groups.map(\.name) == ["Work"])
        #expect(reader.projects.first?.groupID == group?.id)
        #expect(reader.projects(in: group?.id).map(\.id) == [p.id])
    }

    @Test
    func removeGroup_ungroups_projects_without_deleting_them() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-rmg-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-groups-rmg-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        let store = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        let a = store.create(name: "a", path: "/tmp/a")
        let b = store.create(name: "b", path: "/tmp/b")
        let group = try #require(store.createGroup(name: "Work"))
        store.setGroup(projectID: a.id, groupID: group.id)
        store.setGroup(projectID: b.id, groupID: group.id)
        store.removeGroup(id: group.id)

        #expect(store.groups.isEmpty)
        #expect(store.projects.count == 2)
        #expect(store.projects.allSatisfy { $0.groupID == nil })

        let reader = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        #expect(reader.groups.isEmpty)
        #expect(reader.projects.count == 2)
        #expect(reader.projects.allSatisfy { $0.groupID == nil })
    }

    @Test
    func reorderGroups_updates_sortOrder() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-rg-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-groups-rg-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        let store = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        let work = try #require(store.createGroup(name: "Work"))
        let home = try #require(store.createGroup(name: "Home"))
        store.reorderGroups(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(store.groups.map(\.id) == [home.id, work.id])
        #expect(store.groups.map(\.sortOrder) == [0, 1])

        let reader = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        #expect(reader.groups.map(\.id) == [home.id, work.id])
        #expect(reader.groups.map(\.sortOrder) == [0, 1])
    }

    @Test
    func remove_project_does_not_delete_its_group() throws {
        let store = makeStore()
        let p = store.create(name: "a", path: "/tmp/a")
        let group = try #require(store.createGroup(name: "Work"))
        store.setGroup(projectID: p.id, groupID: group.id)
        store.remove(id: p.id)
        #expect(store.groups.map(\.id) == [group.id])
        #expect(store.projects.isEmpty)
    }

    @Test
    func groups_load_failure_does_not_block_project_saves() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-ok-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-groups-bad-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        try Data("{ not valid".utf8).write(to: groupsURL)

        let store = ProjectStore(fileURL: fileURL, groupsFileURL: groupsURL)
        store.add(Project(name: "alpha", path: "/tmp/alpha", sortOrder: 0))
        #expect(store.projects.map(\.name) == ["alpha"])
        let loaded = try JSONDecoder().decode([Project].self, from: Data(contentsOf: fileURL))
        #expect(loaded.map(\.name) == ["alpha"])
        #expect(try Data(contentsOf: groupsURL) == Data("{ not valid".utf8))
    }

    @Test
    func sidebarProjectOrder_is_folders_then_ungrouped() throws {
        let store = makeStore()
        let ungrouped = store.create(name: "ungrouped", path: "/tmp/u")
        let a = store.create(name: "a", path: "/tmp/a")
        let b = store.create(name: "b", path: "/tmp/b")
        let c = store.create(name: "c", path: "/tmp/c")
        let work = try #require(store.createGroup(name: "Work"))
        let home = try #require(store.createGroup(name: "Home"))
        store.setGroup(projectID: a.id, groupID: work.id)
        store.setGroup(projectID: b.id, groupID: work.id)
        store.setGroup(projectID: c.id, groupID: home.id)
        store.reorderGroups(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(store.sidebarProjectOrder.map(\.id) == [c.id, a.id, b.id, ungrouped.id])
    }

    @Test
    func dangling_groupID_appears_in_ungrouped_list() {
        let store = makeStore()
        var orphan = Project(name: "orphan", path: "/tmp/orphan", sortOrder: 0)
        orphan.groupID = UUID()
        store.add(orphan)
        #expect(store.groups.isEmpty)
        #expect(store.projects(in: nil).map(\.id) == [orphan.id])
        #expect(store.projects(in: orphan.groupID).isEmpty)
        #expect(store.resolvedGroupID(orphan.groupID) == nil)
    }

    @Test
    func reorderAmongSiblings_moves_within_a_folder() throws {
        let store = makeStore()
        let a = store.create(name: "a", path: "/tmp/a")
        let b = store.create(name: "b", path: "/tmp/b")
        let c = store.create(name: "c", path: "/tmp/c")
        let group = try #require(store.createGroup(name: "Work"))
        store.setGroup(projectID: a.id, groupID: group.id)
        store.setGroup(projectID: b.id, groupID: group.id)
        store.setGroup(projectID: c.id, groupID: group.id, append: true)
        #expect(store.projects(in: group.id).map(\.id) == [a.id, b.id, c.id])

        store.reorderAmongSiblings(projectID: c.id, toOffset: 0)
        #expect(store.projects(in: group.id).map(\.id) == [c.id, a.id, b.id])

        store.reorderAmongSiblings(projectID: c.id, toOffset: 3)
        #expect(store.projects(in: group.id).map(\.id) == [a.id, b.id, c.id])
    }

    @Test
    func setGroup_append_moves_to_end_of_folder() throws {
        let store = makeStore()
        let a = store.create(name: "a", path: "/tmp/a")
        let b = store.create(name: "b", path: "/tmp/b")
        let outsider = store.create(name: "z", path: "/tmp/z")
        let group = try #require(store.createGroup(name: "Work"))
        store.setGroup(projectID: a.id, groupID: group.id)
        store.setGroup(projectID: b.id, groupID: group.id)
        store.setGroup(projectID: outsider.id, groupID: group.id, append: true)
        #expect(store.projects(in: group.id).map(\.id) == [a.id, b.id, outsider.id])
    }

    @Test
    func decode_groups_missing_parentID_are_roots() throws {
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-groups-noparent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: groupsURL) }
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","name":"Work","sortOrder":0}]
        """
        try Data(json.utf8).write(to: groupsURL)

        let store = makeStore(groupsFileURL: groupsURL)
        #expect(store.groups.count == 1)
        #expect(store.groups.first?.name == "Work")
        #expect(store.groups.first?.parentID == nil)
        #expect(store.childGroups(in: nil).map(\.name) == ["Work"])
        #expect(store.folderDepth(store.groups[0].id) == 1)
    }

    @Test
    func createGroup_nested_round_trips_parentID() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-nested-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-groups-nested-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        let writer = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        #expect(writer.createGroup(name: "   ") == nil)
        #expect(writer.createGroup(name: "Nope", parentID: UUID()) == nil)
        let clients = try #require(writer.createGroup(name: "Clients"))
        let kectil = try #require(writer.createGroup(name: "Kectil", parentID: clients.id))
        #expect(kectil.parentID == clients.id)
        #expect(writer.folderDepth(clients.id) == 1)
        #expect(writer.folderDepth(kectil.id) == 2)
        #expect(writer.childGroups(in: clients.id).map(\.id) == [kectil.id])

        let reader = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        #expect(reader.groups.first { $0.id == kectil.id }?.parentID == clients.id)
        #expect(reader.folderDepth(kectil.id) == 2)
        let decoded = try JSONDecoder().decode([ProjectGroup].self, from: Data(contentsOf: groupsURL))
        #expect(decoded.contains { $0.id == clients.id && $0.parentID == nil })
        #expect(decoded.contains { $0.id == kectil.id && $0.parentID == clients.id })
    }

    @Test
    func createGroup_and_setParent_refuse_depth_five() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let team = try #require(store.createGroup(name: "Team", parentID: kectil.id))
        let leaf = try #require(store.createGroup(name: "Leaf", parentID: team.id))
        #expect(store.folderDepth(clients.id) == 1)
        #expect(store.folderDepth(kectil.id) == 2)
        #expect(store.folderDepth(team.id) == 3)
        #expect(store.folderDepth(leaf.id) == 4)
        #expect(store.folderDepth(leaf.id) == ProjectStore.maxFolderDepth)
        #expect(store.folderPathNames(for: leaf.id) == ["Clients", "Kectil", "Team", "Leaf"])
        let allOpen = store.sidebarFolderRows(expanded: [clients.id, kectil.id, team.id])
        #expect(allOpen.map(\.group.id) == [clients.id, kectil.id, team.id, leaf.id])
        #expect(allOpen.map(\.depth) == [1, 2, 3, 4])
        let teamCollapsed = store.sidebarFolderRows(expanded: [clients.id, kectil.id])
        #expect(teamCollapsed.map(\.group.id) == [clients.id, kectil.id, team.id])
        #expect(store.createGroup(name: "TooDeep", parentID: leaf.id) == nil)
        #expect(store.groups.map(\.name) == ["Clients", "Kectil", "Team", "Leaf"])

        let stray = try #require(store.createGroup(name: "Stray"))
        store.setParent(groupID: stray.id, parentID: leaf.id)
        let strayAfterLeaf = try #require(store.groups.first { $0.id == stray.id })
        #expect(strayAfterLeaf.parentID == nil)
        #expect(store.folderDepth(stray.id) == 1)

        store.setParent(groupID: stray.id, parentID: team.id)
        let strayUnderTeam = try #require(store.groups.first { $0.id == stray.id })
        #expect(strayUnderTeam.parentID == team.id)
        #expect(store.folderDepth(stray.id) == 4)
        #expect(store.childGroups(in: team.id).map(\.id) == [leaf.id, stray.id])

        let extra = try #require(store.createGroup(name: "Extra"))
        let extraChild = try #require(store.createGroup(name: "ExtraChild", parentID: extra.id))
        store.setParent(groupID: extra.id, parentID: team.id)
        let extraAfterTeam = try #require(store.groups.first { $0.id == extra.id })
        let extraChildAfterTeam = try #require(store.groups.first { $0.id == extraChild.id })
        #expect(extraAfterTeam.parentID == nil)
        #expect(extraChildAfterTeam.parentID == extra.id)
        #expect(store.childGroups(in: nil).map(\.id) == [clients.id, extra.id])

        store.setParent(groupID: extra.id, parentID: kectil.id)
        let extraUnderKectil = try #require(store.groups.first { $0.id == extra.id })
        let extraChildUnderKectil = try #require(store.groups.first { $0.id == extraChild.id })
        #expect(extraUnderKectil.parentID == kectil.id)
        #expect(extraChildUnderKectil.parentID == extra.id)
        #expect(store.folderDepth(extra.id) == 3)
        #expect(store.folderDepth(extraChild.id) == 4)
        #expect(store.childGroups(in: kectil.id).map(\.id) == [team.id, extra.id])
    }

    @Test
    func setParent_refuses_cycles() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        store.setParent(groupID: clients.id, parentID: clients.id)
        #expect(store.groups.first { $0.id == clients.id }?.parentID == nil)
        store.setParent(groupID: clients.id, parentID: kectil.id)
        #expect(store.groups.first { $0.id == clients.id }?.parentID == nil)
        #expect(store.groups.first { $0.id == kectil.id }?.parentID == clients.id)
    }

    @Test
    func removeGroup_nested_reparents_projects_to_parent() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let nested = store.create(name: "nested", path: "/tmp/nested")
        let sibling = store.create(name: "sibling", path: "/tmp/sibling")
        store.setGroup(projectID: nested.id, groupID: kectil.id)
        store.setGroup(projectID: sibling.id, groupID: clients.id)
        store.removeGroup(id: kectil.id)

        #expect(store.groups.map(\.id) == [clients.id])
        #expect(store.projects.count == 2)
        #expect(store.projects.first { $0.id == nested.id }?.groupID == clients.id)
        #expect(store.projects.first { $0.id == sibling.id }?.groupID == clients.id)

        let grandchild = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let inner = store.create(name: "inner", path: "/tmp/inner")
        store.setGroup(projectID: inner.id, groupID: grandchild.id)
        store.removeGroup(id: clients.id)
        #expect(store.groups.map(\.id) == [grandchild.id])
        #expect(store.groups.first?.parentID == nil)
        #expect(store.projects.first { $0.id == inner.id }?.groupID == grandchild.id)
        #expect(store.projects.first { $0.id == nested.id }?.groupID == nil)
    }

    @Test
    func sidebarProjectOrder_dfs_nested_then_parent_then_ungrouped() throws {
        let store = makeStore()
        let ungrouped = store.create(name: "ungrouped", path: "/tmp/u")
        let a = store.create(name: "a", path: "/tmp/a")
        let b = store.create(name: "b", path: "/tmp/b")
        let c = store.create(name: "c", path: "/tmp/c")
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        store.setGroup(projectID: a.id, groupID: kectil.id)
        store.setGroup(projectID: b.id, groupID: kectil.id)
        store.setGroup(projectID: c.id, groupID: clients.id)
        #expect(store.sidebarProjectOrder.map(\.id) == [a.id, b.id, c.id, ungrouped.id])
    }

    @Test
    func sidebarFolderRows_omits_collapsed_descendants() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let team = try #require(store.createGroup(name: "Team", parentID: kectil.id))
        let collapsed = store.sidebarFolderRows(expanded: [])
        #expect(collapsed.map(\.group.id) == [clients.id])
        #expect(collapsed.map(\.depth) == [1])
        let clientsOpen = store.sidebarFolderRows(expanded: [clients.id])
        #expect(clientsOpen.map(\.group.id) == [clients.id, kectil.id])
        #expect(clientsOpen.map(\.depth) == [1, 2])
        let allOpen = store.sidebarFolderRows(expanded: [clients.id, kectil.id])
        #expect(allOpen.map(\.group.id) == [clients.id, kectil.id, team.id])
        #expect(allOpen.map(\.depth) == [1, 2, 3])
        let grandchildOnly = store.sidebarFolderRows(expanded: [kectil.id])
        #expect(grandchildOnly.map(\.group.id) == [clients.id])
    }

    @Test
    func ancestorFolderIDs_walks_from_nested_folder_to_root() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let team = try #require(store.createGroup(name: "Team", parentID: kectil.id))
        let nested = store.create(name: "nested", path: "/tmp/nested")
        let ungrouped = store.create(name: "ungrouped", path: "/tmp/ungrouped")
        store.setGroup(projectID: nested.id, groupID: kectil.id)
        let nestedGroupID = store.projects.first { $0.id == nested.id }?.groupID

        #expect(store.ancestorFolderIDs(kectil.id) == [kectil.id, clients.id])
        #expect(nestedGroupID == kectil.id)
        #expect(store.ancestorFolderIDs(nestedGroupID) == [kectil.id, clients.id])
        #expect(store.ancestorFolderIDs(ungrouped.groupID).isEmpty)
        #expect(store.ancestorFolderIDs(nil).isEmpty)
        #expect(store.ancestorFolderIDs(UUID()).isEmpty)
        #expect(store.ancestorFolderIDs(clients.id) == [clients.id])
        #expect(store.ancestorFolderIDs(team.id) == [team.id, kectil.id, clients.id])

        // Immediate-only expand is the POR-328 behavior this leaf supersedes:
        // Kectil stays hidden until Clients is also expanded.
        let kectilOnly = store.sidebarFolderRows(expanded: [kectil.id])
        #expect(kectilOnly.map(\.group.id) == [clients.id])
        #expect(kectilOnly.map(\.depth) == [1])

        let expanded = Set(store.ancestorFolderIDs(nestedGroupID))
        #expect(expanded == [kectil.id, clients.id])
        let visibleWhenActive = store.sidebarFolderRows(expanded: expanded)
        #expect(visibleWhenActive.map(\.group.id) == [clients.id, kectil.id, team.id])
        #expect(visibleWhenActive.map(\.depth) == [1, 2, 3])

        let teamChain = store.sidebarFolderRows(expanded: Set(store.ancestorFolderIDs(team.id)))
        #expect(teamChain.map(\.group.id) == [clients.id, kectil.id, team.id])
        #expect(teamChain.map(\.depth) == [1, 2, 3])
    }

    @Test
    func flattened_section_project_order_differs_from_sidebarProjectOrder_dfs() throws {
        // Visual Sections emit parent projects before the child-folder Section.
        // `sidebarProjectOrder` is DFS (child-folder projects first). POR-329
        // owns matching keyboard cycle to the flattened outline.
        let store = makeStore()
        let ungrouped = store.create(name: "ungrouped", path: "/tmp/u")
        let a = store.create(name: "a", path: "/tmp/a")
        let b = store.create(name: "b", path: "/tmp/b")
        let c = store.create(name: "c", path: "/tmp/c")
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        store.setGroup(projectID: a.id, groupID: kectil.id)
        store.setGroup(projectID: b.id, groupID: kectil.id)
        store.setGroup(projectID: c.id, groupID: clients.id)

        #expect(store.sidebarProjectOrder.map(\.id) == [a.id, b.id, c.id, ungrouped.id])

        let rows = store.sidebarFolderRows(expanded: [clients.id, kectil.id])
        var visual: [UUID] = []
        for row in rows {
            visual.append(contentsOf: store.projects(in: row.group.id).map(\.id))
        }
        visual.append(contentsOf: store.projects(in: nil).map(\.id))
        #expect(visual == [c.id, a.id, b.id, ungrouped.id])
        #expect(visual != store.sidebarProjectOrder.map(\.id))
    }

    @Test
    func ancestorFolderIDs_dangling_group_and_parent_are_empty_or_root() throws {
        let danglingParent = ProjectGroup(
            id: UUID(),
            name: "DanglingParent",
            sortOrder: 0,
            parentID: UUID()
        )
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-groups-ancestors-\(UUID().uuidString).json")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-ancestors-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: groupsURL)
            try? FileManager.default.removeItem(at: fileURL)
        }
        try JSONEncoder().encode([danglingParent]).write(to: groupsURL)
        let loaded = ProjectStore(fileURL: fileURL, groupsFileURL: groupsURL)
        #expect(loaded.ancestorFolderIDs(danglingParent.id) == [danglingParent.id])

        let orphanGroupID = UUID()
        loaded.add(Project(name: "orphan", path: "/tmp/orphan", sortOrder: 0, groupID: orphanGroupID))
        let orphan = try #require(loaded.projects.first)
        #expect(loaded.ancestorFolderIDs(orphan.groupID).isEmpty)
        #expect(loaded.resolvedGroupID(orphan.groupID) == nil)
    }

    @Test
    func reorderGroupsAmongSiblings_does_not_change_parent() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let alpha = try #require(store.createGroup(name: "Alpha", parentID: clients.id))
        let beta = try #require(store.createGroup(name: "Beta", parentID: clients.id))
        #expect(store.childGroups(in: clients.id).map(\.id) == [alpha.id, beta.id])
        store.reorderGroupsAmongSiblings(groupID: beta.id, toOffset: 0)
        #expect(store.childGroups(in: clients.id).map(\.id) == [beta.id, alpha.id])
        #expect(store.groups.first { $0.id == beta.id }?.parentID == clients.id)
        #expect(store.groups.first { $0.id == alpha.id }?.parentID == clients.id)
        store.reorderGroups(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        #expect(store.groups.first { $0.id == beta.id }?.parentID == clients.id)
    }

    @Test
    func dangling_parentID_is_treated_as_root() throws {
        let dangling = ProjectGroup(id: UUID(), name: "Dangling", sortOrder: 0, parentID: UUID())
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-groups-dangling-\(UUID().uuidString).json")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-dangling-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: groupsURL)
            try? FileManager.default.removeItem(at: fileURL)
        }
        try JSONEncoder().encode([dangling]).write(to: groupsURL)
        let loaded = ProjectStore(fileURL: fileURL, groupsFileURL: groupsURL)
        #expect(loaded.resolvedParentID(dangling.parentID) == nil)
        #expect(loaded.childGroups(in: nil).map(\.id) == [dangling.id])
        #expect(loaded.folderDepth(dangling.id) == 1)
    }

    @Test
    func load_breaks_parent_cycles_without_groupsLoadFailed() throws {
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-groups-cycle-\(UUID().uuidString).json")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-project-store-cycle-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: groupsURL)
            try? FileManager.default.removeItem(at: fileURL)
        }
        let aID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let bID = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        let cyclic = [
            ProjectGroup(id: aID, name: "A", sortOrder: 0, parentID: bID),
            ProjectGroup(id: bID, name: "B", sortOrder: 1, parentID: aID),
        ]
        try JSONEncoder().encode(cyclic).write(to: groupsURL)
        let store = ProjectStore(fileURL: fileURL, groupsFileURL: groupsURL)
        let aParent = store.groups.first { $0.id == aID }?.parentID
        let bParent = store.groups.first { $0.id == bID }?.parentID
        #expect(aParent == nil || bParent == nil)
        assertAncestorWalkIsFinite(store, aID)
        assertAncestorWalkIsFinite(store, bID)
        store.add(Project(name: "alpha", path: "/tmp/alpha", sortOrder: 0))
        let loaded = try JSONDecoder().decode([Project].self, from: Data(contentsOf: fileURL))
        #expect(loaded.map(\.name) == ["alpha"])
    }

    @Test
    func save_refuses_after_corrupt_load_so_a_mutation_cannot_clobber() throws {
        // A present-but-undecodable projects.json must NOT be overwritten by the
        // first subsequent mutation — that would wipe the user's project list.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let garbage = Data("{ not valid json".utf8)
        try garbage.write(to: fileURL)

        // init loads (and latches the failure); a mutation then triggers save().
        let store = makeStore(fileURL: fileURL)
        #expect(store.projects.isEmpty)
        store.add(Project(name: "alpha", path: "/tmp/alpha", sortOrder: 0))

        // The corrupt file is preserved, not clobbered with the empty/new state.
        #expect(try Data(contentsOf: fileURL) == garbage)
    }

    @Test
    func groups_json_without_parentID_loads_as_roots() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-legacy-g-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-groups-legacy-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        let json = """
        [{"id":"22222222-2222-2222-2222-222222222222","name":"Work","sortOrder":0}]
        """
        try Data(json.utf8).write(to: groupsURL)

        let store = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        let loaded = try #require(store.groups.first)
        #expect(store.groups.count == 1)
        #expect(loaded.name == "Work")
        #expect(loaded.parentID == nil)
        #expect(store.childGroups(in: nil).map(\.name) == ["Work"])
        let decoded = try JSONDecoder().decode([ProjectGroup].self, from: Data(contentsOf: groupsURL))
        #expect(decoded.count == 1)
        #expect(decoded[0].parentID == nil)
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: groupsURL)) is [Any])
    }

    @Test
    func nested_createGroup_round_trips_parentID() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-nest-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-groups-nest-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        let writer = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        let clients = try #require(writer.createGroup(name: "Clients"))
        let kectil = try #require(writer.createGroup(name: "Kectil", parentID: clients.id))
        #expect(kectil.parentID == clients.id)
        #expect(writer.folderDepth(clients.id) == 1)
        #expect(writer.folderDepth(kectil.id) == 2)
        #expect(writer.childGroups(in: clients.id).map(\.id) == [kectil.id])

        let reader = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        #expect(reader.groups.first { $0.id == kectil.id }?.parentID == clients.id)
        #expect(reader.folderDepth(kectil.id) == 2)
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: groupsURL)) is [Any])
    }

    @Test
    func removeGroup_on_nested_folder_reparents_projects_to_parent() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let a = store.create(name: "a", path: "/tmp/a")
        let b = store.create(name: "b", path: "/tmp/b")
        store.setGroup(projectID: a.id, groupID: kectil.id)
        store.setGroup(projectID: b.id, groupID: kectil.id)
        store.removeGroup(id: kectil.id)

        #expect(store.groups.map(\.id) == [clients.id])
        #expect(store.projects.count == 2)
        #expect(store.projects.allSatisfy { $0.groupID == clients.id })
        #expect(store.projects(in: clients.id).map(\.id) == [a.id, b.id])
    }

    @Test
    func removeGroup_lifts_child_folders_without_deleting_them() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let team = try #require(store.createGroup(name: "Team", parentID: kectil.id))
        let nested = store.create(name: "nested", path: "/tmp/nested")
        store.setGroup(projectID: nested.id, groupID: team.id)
        store.removeGroup(id: kectil.id)

        #expect(Set(store.groups.map(\.id)) == Set([clients.id, team.id]))
        #expect(store.groups.first { $0.id == team.id }?.parentID == clients.id)
        #expect(store.projects.first { $0.id == nested.id }?.groupID == team.id)
    }

    @Test
    func sidebarFolderRows_keeps_sibling_roots_when_a_tree_collapses() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let team = try #require(store.createGroup(name: "Team", parentID: kectil.id))
        let home = try #require(store.createGroup(name: "Home"))

        let collapsed = store.sidebarFolderRows(expanded: [])
        #expect(collapsed.map(\.group.id) == [clients.id, home.id])
        #expect(collapsed.map(\.depth) == [1, 1])

        let clientsOpen = store.sidebarFolderRows(expanded: [clients.id])
        #expect(clientsOpen.map(\.group.id) == [clients.id, kectil.id, home.id])
        #expect(clientsOpen.map(\.depth) == [1, 2, 1])

        let allOpen = store.sidebarFolderRows(expanded: [clients.id, kectil.id])
        #expect(allOpen.map(\.group.id) == [clients.id, kectil.id, team.id, home.id])
        #expect(allOpen.map(\.depth) == [1, 2, 3, 1])
    }

    @Test
    func projects_inSubtreeOf_includes_nested_folder_projects() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let team = try #require(store.createGroup(name: "Team", parentID: kectil.id))
        let home = try #require(store.createGroup(name: "Home"))
        let clientsDirect = store.create(name: "clients-root", path: "/tmp/clients-root")
        let kectilProj = store.create(name: "kectil", path: "/tmp/kectil")
        let teamProj = store.create(name: "team", path: "/tmp/team")
        let homeProj = store.create(name: "home", path: "/tmp/home")
        let ungrouped = store.create(name: "ungrouped", path: "/tmp/ungrouped")
        store.setGroup(projectID: clientsDirect.id, groupID: clients.id)
        store.setGroup(projectID: kectilProj.id, groupID: kectil.id)
        store.setGroup(projectID: teamProj.id, groupID: team.id)
        store.setGroup(projectID: homeProj.id, groupID: home.id)

        #expect(store.projects(inSubtreeOf: clients.id).map(\.id) == [
            clientsDirect.id, kectilProj.id, teamProj.id,
        ])
        #expect(store.projects(inSubtreeOf: kectil.id).map(\.id) == [kectilProj.id, teamProj.id])
        #expect(store.projects(inSubtreeOf: team.id).map(\.id) == [teamProj.id])
        #expect(store.projects(inSubtreeOf: home.id).map(\.id) == [homeProj.id])
        #expect(store.projects(inSubtreeOf: UUID()).isEmpty)
        #expect(!store.projects(inSubtreeOf: clients.id).map(\.id).contains(ungrouped.id))
        #expect(!store.projects(inSubtreeOf: clients.id).map(\.id).contains(homeProj.id))
    }

    @Test
    func visibleGroupedProjectIDs_follows_expanded_folder_rows() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let home = try #require(store.createGroup(name: "Home"))
        let clientsDirect = store.create(name: "clients-root", path: "/tmp/clients-root")
        let kectilProj = store.create(name: "kectil", path: "/tmp/kectil")
        let homeProj = store.create(name: "home", path: "/tmp/home")
        let ungrouped = store.create(name: "ungrouped", path: "/tmp/ungrouped")
        store.setGroup(projectID: clientsDirect.id, groupID: clients.id)
        store.setGroup(projectID: kectilProj.id, groupID: kectil.id)
        store.setGroup(projectID: homeProj.id, groupID: home.id)

        #expect(store.visibleGroupedProjectIDs(expanded: []).isEmpty)

        let parentOpen = store.visibleGroupedProjectIDs(expanded: [clients.id])
        #expect(parentOpen == [clientsDirect.id])
        #expect(!parentOpen.contains(kectilProj.id))
        #expect(!parentOpen.contains(ungrouped.id))

        let bothOpen = store.visibleGroupedProjectIDs(expanded: [clients.id, kectil.id])
        #expect(bothOpen == [clientsDirect.id, kectilProj.id])

        let homeOpen = store.visibleGroupedProjectIDs(expanded: [home.id])
        #expect(homeOpen == [homeProj.id])
        #expect(!homeOpen.contains(ungrouped.id))
    }

    @Test
    func projects_inSubtreeOf_cycle_does_not_infinite_loop() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-subtree-cycle-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-groups-subtree-cycle-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        let aID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let bID = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        let cyclic = [
            ProjectGroup(id: aID, name: "A", sortOrder: 0, parentID: bID),
            ProjectGroup(id: bID, name: "B", sortOrder: 1, parentID: aID),
        ]
        try JSONEncoder().encode(cyclic).write(to: groupsURL)
        let store = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        let aProj = store.create(name: "a", path: "/tmp/a")
        let bProj = store.create(name: "b", path: "/tmp/b")
        store.setGroup(projectID: aProj.id, groupID: aID)
        store.setGroup(projectID: bProj.id, groupID: bID)
        let aProjects = store.projects(inSubtreeOf: aID)
        let bProjects = store.projects(inSubtreeOf: bID)
        #expect(Set(aProjects.map(\.id)).count == aProjects.count)
        #expect(Set(bProjects.map(\.id)).count == bProjects.count)
        #expect(aProjects.count <= store.projects.count)
        #expect(bProjects.count <= store.projects.count)
        assertAncestorWalkIsFinite(store, aID)
        assertAncestorWalkIsFinite(store, bID)
    }

    @Test
    func reorderGroupsAmongSiblings_preserves_parent_after_sibling_move() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let other = try #require(store.createGroup(name: "Other", parentID: clients.id))
        store.reorderGroupsAmongSiblings(groupID: other.id, toOffset: 0)
        #expect(store.childGroups(in: clients.id).map(\.id) == [other.id, kectil.id])
        #expect(store.groups.first { $0.id == other.id }?.parentID == clients.id)
        #expect(store.groups.first { $0.id == kectil.id }?.parentID == clients.id)
    }

    @Test
    func reorderGroupsAmongSiblings_uses_menu_toOffset_on_nested_children() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let alpha = try #require(store.createGroup(name: "Alpha", parentID: clients.id))
        let beta = try #require(store.createGroup(name: "Beta", parentID: clients.id))
        let alphaPos = folderMenuSiblingIndex(store, alpha)
        let betaPos = folderMenuSiblingIndex(store, beta)
        #expect(alphaPos.index == 0)
        #expect(alphaPos.count == 2)
        #expect(betaPos.index == 1)
        #expect(betaPos.index >= betaPos.count - 1)

        store.reorderGroupsAmongSiblings(groupID: beta.id, toOffset: 0)
        #expect(store.childGroups(in: clients.id).map(\.id) == [beta.id, alpha.id])
        #expect(store.groups.first { $0.id == alpha.id }?.parentID == clients.id)
        #expect(store.groups.first { $0.id == beta.id }?.parentID == clients.id)

        store.reorderGroupsAmongSiblings(groupID: beta.id, toOffset: 2)
        #expect(store.childGroups(in: clients.id).map(\.id) == [alpha.id, beta.id])
        #expect(store.groups.first { $0.id == alpha.id }?.parentID == clients.id)
        #expect(store.groups.first { $0.id == beta.id }?.parentID == clients.id)
    }

    @Test
    func folderMenu_disables_last_root_down_when_nested_folders_exist() throws {
        let store = makeStore()
        let work = try #require(store.createGroup(name: "Work"))
        let home = try #require(store.createGroup(name: "Home"))
        let nested = try #require(store.createGroup(name: "Nested", parentID: work.id))
        #expect(store.childGroups(in: nil).map(\.id) == [work.id, home.id])
        #expect(store.groups.count > store.childGroups(in: nil).count)

        let homePos = folderMenuSiblingIndex(store, home)
        #expect(homePos.index == 1)
        #expect(homePos.count == 2)
        #expect(homePos.index >= homePos.count - 1)

        let workPos = folderMenuSiblingIndex(store, work)
        #expect(workPos.index == 0)
        #expect(workPos.index <= 0)

        store.reorderGroupsAmongSiblings(groupID: home.id, toOffset: 0)
        #expect(store.childGroups(in: nil).map(\.id) == [home.id, work.id])
        #expect(store.groups.first { $0.id == nested.id }?.parentID == work.id)
    }

    @Test
    func reorderGroups_out_of_range_destination_is_a_noop_when_nested_exist() throws {
        let store = makeStore()
        let work = try #require(store.createGroup(name: "Work"))
        let home = try #require(store.createGroup(name: "Home"))
        let nested = try #require(store.createGroup(name: "Nested", parentID: work.id))
        store.reorderGroups(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        #expect(store.childGroups(in: nil).map(\.id) == [work.id, home.id])
        #expect(store.groups.first { $0.id == nested.id }?.parentID == work.id)
    }

    @Test
    func reorderGroupsAmongSiblings_swaps_two_roots_without_nested() throws {
        let store = makeStore()
        let work = try #require(store.createGroup(name: "Work"))
        let home = try #require(store.createGroup(name: "Home"))
        store.reorderGroupsAmongSiblings(groupID: work.id, toOffset: 2)
        #expect(store.childGroups(in: nil).map(\.id) == [home.id, work.id])
        store.reorderGroupsAmongSiblings(groupID: work.id, toOffset: 0)
        #expect(store.childGroups(in: nil).map(\.id) == [work.id, home.id])
    }

    @Test
    func dangling_parentID_in_json_is_treated_as_root() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-dangling-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-groups-dangling-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        let json = """
        [{"id":"33333333-3333-3333-3333-333333333333","name":"Work","sortOrder":0,"parentID":"99999999-9999-9999-9999-999999999999"}]
        """
        try Data(json.utf8).write(to: groupsURL)
        let store = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        let work = try #require(store.groups.first)
        #expect(work.parentID != nil)
        #expect(store.resolvedParentID(work.parentID) == nil)
        #expect(store.childGroups(in: nil).map(\.id) == [work.id])
        #expect(store.folderDepth(work.id) == 1)
    }

    @Test
    func loadGroups_breaks_parent_cycles() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-store-cycle-\(UUID().uuidString).json")
        let groupsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("futuraterm-project-groups-cycle-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: groupsURL)
        }
        let json = """
        [
          {"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"A","sortOrder":0,
           "parentID":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"},
          {"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","name":"B","sortOrder":1,
           "parentID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}
        ]
        """
        try Data(json.utf8).write(to: groupsURL)
        let store = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        #expect(store.groups.count == 2)
        let a = try #require(store.groups.first { $0.name == "A" })
        let b = try #require(store.groups.first { $0.name == "B" })
        #expect(store.resolvedParentID(a.parentID) == nil || store.resolvedParentID(b.parentID) == nil)
        #expect(store.folderDepth(a.id) != nil)
        #expect(store.folderDepth(b.id) != nil)
        assertAncestorWalkIsFinite(store, a.id)
        assertAncestorWalkIsFinite(store, b.id)
        store.renameGroup(id: a.id, to: "A2")
        let reloaded = makeStore(fileURL: fileURL, groupsFileURL: groupsURL)
        let ra = try #require(reloaded.groups.first { $0.name == "A2" })
        let rb = try #require(reloaded.groups.first { $0.name == "B" })
        #expect(reloaded.resolvedParentID(ra.parentID) == nil || reloaded.resolvedParentID(rb.parentID) == nil)
    }

    @Test
    func createGroup_unknown_parent_returns_nil() {
        let store = makeStore()
        #expect(store.createGroup(name: "Nested", parentID: UUID()) == nil)
        #expect(store.groups.isEmpty)
    }

    @Test
    func setParent_unknown_ids_are_noops() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        store.setParent(groupID: UUID(), parentID: clients.id)
        store.setParent(groupID: clients.id, parentID: UUID())
        #expect(store.groups.first { $0.id == clients.id }?.parentID == nil)
        #expect(store.groups.count == 1)
    }

    @Test
    func folderPathNames_clients_kectil_is_root_first() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        #expect(store.folderPathNames(for: clients.id) == ["Clients"])
        #expect(store.folderPathNames(for: kectil.id) == ["Clients", "Kectil"])
        let team = try #require(store.createGroup(name: "Team", parentID: kectil.id))
        #expect(store.folderPathNames(for: team.id) == ["Clients", "Kectil", "Team"])
        // Settings caption walks this list then the project path.
        let nested = store.create(name: "nested", path: "/tmp/nested")
        store.setGroup(projectID: nested.id, groupID: kectil.id)
        let grouped = try #require(store.projects.first { $0.id == nested.id })
        #expect(grouped.groupID == kectil.id)
        let names = store.folderPathNames(for: kectil.id)
        #expect(names == ["Clients", "Kectil"])
        #expect((names + [grouped.path]).joined(separator: " · ") == "Clients · Kectil · /tmp/nested")

        store.removeGroup(id: kectil.id)
        let lifted = try #require(store.projects.first { $0.id == nested.id })
        let liftedID = try #require(lifted.groupID)
        #expect(liftedID == clients.id)
        #expect(store.folderPathNames(for: liftedID) == ["Clients"])
        #expect(store.childGroups(in: clients.id).map(\.name) == ["Team"])
        #expect(
            (store.folderPathNames(for: liftedID) + [lifted.path])
                .joined(separator: " · ") == "Clients · /tmp/nested"
        )
    }

    @Test
    func folderPathNames_unknown_id_is_empty() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        #expect(store.folderPathNames(for: clients.id) == ["Clients"])
        #expect(store.folderPathNames(for: kectil.id) == ["Clients", "Kectil"])
        #expect(store.folderPathNames(for: UUID()).isEmpty)
        #expect(store.groups.count == 2)
    }

    @Test
    func canSetParent_cycle_and_depth_rules() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let team = try #require(store.createGroup(name: "Team", parentID: kectil.id))
        let leaf = try #require(store.createGroup(name: "Leaf", parentID: team.id))
        #expect(!store.canSetParent(groupID: kectil.id, parentID: kectil.id))
        #expect(!store.canSetParent(groupID: clients.id, parentID: kectil.id))
        #expect(store.canSetParent(groupID: kectil.id, parentID: clients.id))
        #expect(!store.canSetParent(groupID: UUID(), parentID: clients.id))
        #expect(!store.canSetParent(groupID: clients.id, parentID: UUID()))

        let stray = try #require(store.createGroup(name: "Stray"))
        #expect(!store.canSetParent(groupID: stray.id, parentID: leaf.id))
        #expect(store.canSetParent(groupID: stray.id, parentID: team.id))

        let extra = try #require(store.createGroup(name: "Extra"))
        _ = try #require(store.createGroup(name: "ExtraChild", parentID: extra.id))
        #expect(!store.canSetParent(groupID: extra.id, parentID: team.id))
        #expect(store.canSetParent(groupID: extra.id, parentID: kectil.id))
        #expect(store.canSetParent(groupID: extra.id, parentID: nil))
        #expect(store.canCreateChildFolder(in: team.id))
        #expect(!store.canCreateChildFolder(in: leaf.id))
        #expect(!store.canCreateChildFolder(in: UUID()))
    }

    @Test
    func setParent_nil_makes_nested_folder_a_root() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let kectil = try #require(store.createGroup(name: "Kectil", parentID: clients.id))
        let home = try #require(store.createGroup(name: "Home"))
        store.setParent(groupID: kectil.id, parentID: nil)
        let moved = try #require(store.groups.first { $0.id == kectil.id })
        #expect(moved.parentID == nil)
        #expect(store.childGroups(in: nil).map(\.id) == [clients.id, home.id, kectil.id])
        #expect(store.childGroups(in: clients.id).isEmpty)
    }

    @Test
    func setParent_appends_after_reordered_destination_siblings() throws {
        let store = makeStore()
        let team = try #require(store.createGroup(name: "Team"))
        let leaf = try #require(store.createGroup(name: "Leaf", parentID: team.id))
        let alpha = try #require(store.createGroup(name: "Alpha", parentID: team.id))
        store.reorderGroupsAmongSiblings(groupID: alpha.id, toOffset: 0)
        #expect(store.childGroups(in: team.id).map(\.id) == [alpha.id, leaf.id])

        let origin = try #require(store.createGroup(name: "Origin"))
        let first = try #require(store.createGroup(name: "First", parentID: origin.id))
        let second = try #require(store.createGroup(name: "Second", parentID: origin.id))
        let firstAtOrigin = try #require(store.groups.first { $0.id == first.id })
        #expect(firstAtOrigin.sortOrder == 0)
        #expect(store.childGroups(in: origin.id).map(\.id) == [first.id, second.id])

        store.setParent(groupID: first.id, parentID: team.id)
        let moved = try #require(store.groups.first { $0.id == first.id })
        #expect(moved.parentID == team.id)
        #expect(store.childGroups(in: team.id).map(\.id) == [alpha.id, leaf.id, first.id])
        #expect(store.childGroups(in: origin.id).map(\.id) == [second.id])
    }

    @Test
    func createGroup_nested_appends_after_existing_siblings() throws {
        let store = makeStore()
        let clients = try #require(store.createGroup(name: "Clients"))
        let alpha = try #require(store.createGroup(name: "Alpha", parentID: clients.id))
        let beta = try #require(store.createGroup(name: "Beta", parentID: clients.id))
        store.reorderGroupsAmongSiblings(groupID: beta.id, toOffset: 0)
        #expect(store.childGroups(in: clients.id).map(\.id) == [beta.id, alpha.id])
        let gamma = try #require(store.createGroup(name: "Gamma", parentID: clients.id))
        #expect(gamma.parentID == clients.id)
        #expect(store.childGroups(in: clients.id).map(\.id) == [beta.id, alpha.id, gamma.id])
        #expect(store.childGroups(in: nil).map(\.id) == [clients.id])
    }
}
