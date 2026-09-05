import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectStore")

@MainActor @Observable
final class ProjectStore {
    /// Maximum folder chain length. Root depth is 1; projects are not a level.
    static let maxFolderDepth = 4

    private(set) var projects: [Project] = []
    private(set) var groups: [ProjectGroup] = []
    private let fileURL: URL
    private let groupsFileURL: URL
    /// Set when `load()` found a present-but-undecodable projects.json. While
    /// set, `save()` refuses to overwrite — a transient read/decode failure
    /// must never let the next mutation wipe the user's entire project list.
    @ObservationIgnored
    private var loadFailed = false
    /// Independent of `loadFailed`: a corrupt groups file must not block
    /// project writes, and vice versa.
    @ObservationIgnored
    private var groupsLoadFailed = false

    init(
        fileURL: URL = FileStorage.fileURL(filename: "projects.json"),
        groupsFileURL: URL? = nil
    ) {
        self.fileURL = fileURL
        self.groupsFileURL = groupsFileURL
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("project-groups.json")
        load()
        loadGroups()
    }

    func project(matchingPath path: String) -> Project? {
        projects.first { ProjectPath.matches($0.path, path) }
    }

    /// Return the first project whose path matches, else add a new one. The
    /// create-or-select entry point for idempotent callers — the benchmark
    /// harness (which may replay `open-project`) and any script that expects
    /// re-running to be a no-op. Interactive project creation goes through
    /// `create` instead, so the same directory can back several projects.
    @discardableResult
    func findOrCreate(
        name: String,
        path: String,
        zmxPath: String? = nil,
        securityScopedBookmark: Data? = nil
    ) -> Project {
        if let existing = project(matchingPath: path) {
            if let securityScopedBookmark, !existing.isRemote {
                setBookmark(id: existing.id, bookmark: securityScopedBookmark)
                return projects.first { $0.id == existing.id } ?? existing
            }
            return existing
        }
        return create(
            name: name,
            path: path,
            zmxPath: zmxPath,
            securityScopedBookmark: securityScopedBookmark
        )
    }

    /// Always add a new project, even when one already backs this directory.
    /// A directory is not an identity: two projects may share a `path` and
    /// keep wholly independent workspaces (keyed on `Project.id`) and zmx
    /// sessions (named with per-pane entropy). This is the entry point for
    /// user-initiated creation (folder picker, remote sheet, `project create`).
    /// CLI `project create` does not attach a security-scoped bookmark (no
    /// NSOpenPanel); MAS access for those entries is a later Open-panel re-grant.
    @discardableResult
    func create(
        name: String,
        path: String,
        zmxPath: String? = nil,
        securityScopedBookmark: Data? = nil
    ) -> Project {
        let project = Project(
            name: name,
            path: path,
            sortOrder: projects.count,
            zmxPath: zmxPath,
            securityScopedBookmark: securityScopedBookmark
        )
        add(project)
        return project
    }

    func setBookmark(id: UUID, bookmark: Data?) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        guard !projects[index].isRemote else { return }
        projects[index].securityScopedBookmark = bookmark
        save()
    }

    func add(_ project: Project) {
        var project = project
        project.path = ProjectPath.normalizedForStorage(project.path)
        projects.append(project)
        save()
    }

    func remove(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    func rename(id: UUID, to newName: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = newName
        save()
    }

    func setPath(id: UUID, to newPath: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let normalized = ProjectPath.normalizedForStorage(newPath)
        guard projects[index].path != normalized else { return }
        let previous = projects[index].path
        projects[index].path = normalized
        // A bookmark for the old folder still covers a descendant (Replace
        // Project Path with Current Dir). Clearing it here left MAS with
        // `.unused` after relaunch and no re-grant. Drop only when the new
        // path is outside the granted tree.
        if projects[index].securityScopedBookmark != nil,
           !SecurityScopedBookmark.folder(previous, covers: normalized)
        {
            projects[index].securityScopedBookmark = nil
        }
        save()
    }

    /// Set path and bookmark in one save so a new folder is never persisted
    /// with the previous grant already cleared.
    func setPath(id: UUID, to newPath: String, bookmark: Data?) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let normalized = ProjectPath.normalizedForStorage(newPath)
        let bookmarkChanged = projects[index].securityScopedBookmark != bookmark
        guard projects[index].path != normalized || bookmarkChanged else { return }
        projects[index].path = normalized
        if !projects[index].isRemote {
            projects[index].securityScopedBookmark = bookmark
        }
        save()
    }

    func reorder(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        reindexProjects()
        save()
    }

    /// Reorder `projectID` among the projects that share its folder
    /// (`projects(in:)` membership, including dangling IDs as ungrouped).
    /// `toOffset` uses `move(fromOffsets:toOffset:)`.
    func reorderAmongSiblings(projectID: UUID, toOffset: Int) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        let groupID = resolvedGroupID(project.groupID)
        let siblingIDs = projects(in: groupID).map(\.id)
        guard let from = siblingIDs.firstIndex(of: projectID) else { return }
        var ordered = siblingIDs
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: toOffset)
        applySiblingOrder(ordered, groupID: groupID)
        save()
    }

    @discardableResult
    func createGroup(name: String, parentID: UUID? = nil) -> ProjectGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let resolvedParent = resolvedParentID(parentID)
        if let parentID {
            guard resolvedParent == parentID else { return nil }
            guard let parentDepth = folderDepth(parentID),
                  parentDepth + 1 <= Self.maxFolderDepth
            else { return nil }
        }
        let sortOrder = nextGroupSortOrder(in: resolvedParent)
        let group = ProjectGroup(name: trimmed, sortOrder: sortOrder, parentID: resolvedParent)
        groups.append(group)
        saveGroups()
        return group
    }

    func renameGroup(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
        saveGroups()
    }

    /// Drop the folder record and lift its children one level. Projects stay.
    func removeGroup(id: UUID) {
        guard let deleted = groups.first(where: { $0.id == id }) else { return }
        let destination = resolvedParentID(deleted.parentID)
        groups.removeAll { $0.id == id }

        let lifted = groups.filter { $0.parentID == id }.sorted { $0.sortOrder < $1.sortOrder }
        var next = nextGroupSortOrder(in: destination)
        for liftedGroup in lifted {
            guard let index = groups.firstIndex(where: { $0.id == liftedGroup.id }) else { continue }
            groups[index].parentID = destination
            groups[index].sortOrder = next
            next += 1
        }
        for i in projects.indices where projects[i].groupID == id {
            projects[i].groupID = destination
        }
        saveGroups()
        save()
    }

    /// Reorder root folders only (`parentID == nil`). Nested folders stay put.
    func reorderGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        var roots = childGroups(in: nil)
        guard source.allSatisfy({ $0 < roots.count }) else { return }
        guard destination >= 0, destination <= roots.count else { return }
        roots.move(fromOffsets: source, toOffset: destination)
        for i in roots.indices {
            roots[i].sortOrder = i
        }
        let rootIDs = Set(roots.map(\.id))
        let rest = groups.filter { !rootIDs.contains($0.id) }
        groups = roots + rest
        saveGroups()
    }

    /// Move `groupID` among folders that share its resolved parent.
    func reorderGroupsAmongSiblings(groupID: UUID, toOffset: Int) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let parentID = resolvedParentID(group.parentID)
        let siblingIDs = childGroups(in: parentID).map(\.id)
        guard let from = siblingIDs.firstIndex(of: groupID) else { return }
        var ordered = siblingIDs
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: toOffset)
        applyGroupSiblingOrder(ordered)
        saveGroups()
    }

    /// Whether `setParent` would accept this dest (cycle / overflow / unknown
    /// ids are false). Already sitting at `parentID` is still true — the
    /// mutation itself no-ops.
    func canSetParent(groupID: UUID, parentID: UUID?) -> Bool {
        guard groups.contains(where: { $0.id == groupID }) else { return false }
        if let parentID {
            guard groups.contains(where: { $0.id == parentID }) else { return false }
            guard parentID != groupID else { return false }
            guard !isDescendant(parentID, of: groupID) else { return false }
            guard let parentDepth = folderDepth(parentID),
                  parentDepth + subtreeHeight(groupID) <= Self.maxFolderDepth
            else { return false }
            return true
        }
        return subtreeHeight(groupID) <= Self.maxFolderDepth
    }

    /// `parentID` can grow a child folder (known folder strictly below the cap).
    func canCreateChildFolder(in parentID: UUID) -> Bool {
        guard let depth = folderDepth(parentID) else { return false }
        return depth < Self.maxFolderDepth
    }

    /// Reparent `groupID` (nil = make root). Unknown ids, cycles, and
    /// moves that would exceed `maxFolderDepth` are no-ops.
    func setParent(groupID: UUID, parentID: UUID?) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard canSetParent(groupID: groupID, parentID: parentID) else { return }
        let destination = resolvedParentID(parentID)
        guard resolvedParentID(groups[index].parentID) != destination else { return }
        groups[index].parentID = destination
        groups[index].sortOrder = nextGroupSortOrder(in: destination)
        saveGroups()
    }

    func setGroup(projectID: UUID, groupID: UUID?, append: Bool = false) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        if let groupID, !groups.contains(where: { $0.id == groupID }) {
            return
        }
        projects[index].groupID = groupID
        if append {
            let siblingIDs = projects(in: groupID).map(\.id)
            if let from = siblingIDs.firstIndex(of: projectID) {
                var ordered = siblingIDs
                ordered.move(fromOffsets: IndexSet(integer: from), toOffset: siblingIDs.count)
                applySiblingOrder(ordered, groupID: groupID)
            }
        }
        save()
    }

    /// Known folder, else nil (dangling `groupID`s render as ungrouped).
    func resolvedGroupID(_ groupID: UUID?) -> UUID? {
        guard let groupID, groups.contains(where: { $0.id == groupID }) else { return nil }
        return groupID
    }

    /// Known parent folder, else nil (dangling `parentID`s render as roots).
    func resolvedParentID(_ parentID: UUID?) -> UUID? {
        guard let parentID, groups.contains(where: { $0.id == parentID }) else { return nil }
        return parentID
    }

    /// Child folders of `parentID` (nil = roots **or** unknown parent), in `sortOrder`.
    func childGroups(in parentID: UUID?) -> [ProjectGroup] {
        if let parentID {
            guard groups.contains(where: { $0.id == parentID }) else { return [] }
            return groups.filter { $0.parentID == parentID }.sorted { $0.sortOrder < $1.sortOrder }
        }
        let known = Set(groups.map(\.id))
        return groups.filter { group in
            group.parentID.map { !known.contains($0) } ?? true
        }
        .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Root depth is 1. nil if `id` is not a folder.
    func folderDepth(_ id: UUID) -> Int? {
        guard groups.contains(where: { $0.id == id }) else { return nil }
        var depth = 1
        var current = resolvedParentID(groups.first { $0.id == id }?.parentID)
        var seen: Set<UUID> = [id]
        while let parent = current {
            if !seen.insert(parent).inserted { break }
            depth += 1
            current = resolvedParentID(groups.first { $0.id == parent }?.parentID)
        }
        return depth
    }

    /// Root-first folder names from the tree root down to `groupID`.
    /// Empty when `groupID` is unknown.
    func folderPathNames(for groupID: UUID) -> [String] {
        ancestorFolderIDs(groupID).reversed().compactMap { id in
            groups.first { $0.id == id }?.name
        }
    }

    /// `id` plus every ancestor folder, walking `resolvedParentID` until nil.
    /// Empty when `id` is nil or unknown (ungrouped / dangling `groupID`).
    func ancestorFolderIDs(_ id: UUID?) -> [UUID] {
        guard let id, groups.contains(where: { $0.id == id }) else { return [] }
        var result = [id]
        var current = resolvedParentID(groups.first { $0.id == id }?.parentID)
        var seen: Set<UUID> = [id]
        while let parent = current {
            if !seen.insert(parent).inserted { break }
            result.append(parent)
            current = resolvedParentID(groups.first { $0.id == parent }?.parentID)
        }
        return result
    }

    /// 1 + max child subtree heights, or 1 if none. 0 if `id` is unknown.
    func subtreeHeight(_ id: UUID) -> Int {
        subtreeHeight(id, visiting: [])
    }

    /// Projects in `groupID` (nil = ungrouped **or** unknown folder), in array order.
    func projects(in groupID: UUID?) -> [Project] {
        if let groupID {
            guard groups.contains(where: { $0.id == groupID }) else { return [] }
            return projects.filter { $0.groupID == groupID }
        }
        let known = Set(groups.map(\.id))
        return projects.filter { project in
            project.groupID.map { !known.contains($0) } ?? true
        }
    }

    /// Direct members of `groupID` plus every nested child folder's projects.
    /// Unknown id → []. Does not include ungrouped or sibling trees.
    /// Cycle-safe (visiting set), matching `folderDepth` / `sidebarFolderRows`.
    func projects(inSubtreeOf groupID: UUID) -> [Project] {
        guard groups.contains(where: { $0.id == groupID }) else { return [] }
        var result: [Project] = []
        var visiting = Set<UUID>()
        func walk(_ id: UUID) {
            guard visiting.insert(id).inserted else { return }
            result.append(contentsOf: projects(in: id))
            for child in childGroups(in: id) {
                walk(child.id)
            }
        }
        walk(groupID)
        return result
    }

    /// Combined execution of every tab in this folder's subtree workspaces.
    /// A missing workspace contributes nothing (idle). Ungrouped projects
    /// are outside every subtree.
    func folderExecutionState(
        groupID: UUID,
        workspaces: [UUID: Workspace]
    ) -> TerminalExecutionState {
        TerminalExecutionState.combined(
            projects(inSubtreeOf: groupID).flatMap { project in
                workspaces[project.id]?.tabs.map(\.executionState) ?? []
            }
        )
    }

    /// Sidebar visual order: DFS child folders first, then direct projects, then ungrouped.
    var sidebarProjectOrder: [Project] {
        var result: [Project] = []
        var visiting = Set<UUID>()
        func walk(_ parentID: UUID?) {
            for folder in childGroups(in: parentID) {
                guard visiting.insert(folder.id).inserted else { continue }
                walk(folder.id)
                result.append(contentsOf: projects(in: folder.id))
            }
        }
        walk(nil)
        result.append(contentsOf: projects(in: nil))
        return result
    }

    /// Roots always; descendants only when every ancestor is in `expanded`.
    func sidebarFolderRows(expanded: Set<UUID>) -> [(group: ProjectGroup, depth: Int)] {
        var result: [(group: ProjectGroup, depth: Int)] = []
        var visiting = Set<UUID>()
        func walk(_ parentID: UUID?, depth: Int) {
            for folder in childGroups(in: parentID) {
                guard visiting.insert(folder.id).inserted else { continue }
                result.append((group: folder, depth: depth))
                if expanded.contains(folder.id) {
                    walk(folder.id, depth: depth + 1)
                }
            }
        }
        walk(nil, depth: 1)
        return result
    }

    /// Projects whose folder Section is currently showing members: each
    /// `sidebarFolderRows` group whose id is in `expanded`. Ungrouped
    /// projects are never included (they are not behind a folder chevron).
    func visibleGroupedProjectIDs(expanded: Set<UUID>) -> Set<UUID> {
        Set(
            sidebarFolderRows(expanded: expanded)
                .filter { expanded.contains($0.group.id) }
                .flatMap { projects(in: $0.group.id) }
                .map(\.id)
        )
    }

    private func reindexProjects() {
        for i in projects.indices {
            projects[i].sortOrder = i
        }
    }

    private func nextGroupSortOrder(in parentID: UUID?) -> Int {
        (childGroups(in: parentID).map(\.sortOrder).max() ?? -1) + 1
    }

    private func applyGroupSiblingOrder(_ orderedIDs: [UUID]) {
        for (i, id) in orderedIDs.enumerated() {
            guard let index = groups.firstIndex(where: { $0.id == id }) else { continue }
            groups[index].sortOrder = i
        }
    }

    private func subtreeHeight(_ id: UUID, visiting: Set<UUID>) -> Int {
        guard groups.contains(where: { $0.id == id }) else { return 0 }
        if visiting.contains(id) { return 1 }
        var visiting = visiting
        visiting.insert(id)
        let childHeights = childGroups(in: id).map { subtreeHeight($0.id, visiting: visiting) }
        guard let tallest = childHeights.max() else { return 1 }
        return 1 + tallest
    }

    private func isDescendant(_ maybeChild: UUID, of ancestor: UUID) -> Bool {
        var current = resolvedParentID(groups.first { $0.id == maybeChild }?.parentID)
        var seen: Set<UUID> = [maybeChild]
        while let parent = current {
            if parent == ancestor { return true }
            if !seen.insert(parent).inserted { return false }
            current = resolvedParentID(groups.first { $0.id == parent }?.parentID)
        }
        return false
    }

    private func breakGroupCycles() {
        var changed = true
        while changed {
            changed = false
            for i in groups.indices where parentWalkCycles(from: groups[i].id) {
                groups[i].parentID = nil
                changed = true
                break
            }
        }
    }

    private func parentWalkCycles(from id: UUID) -> Bool {
        var seen: Set<UUID> = []
        var current: UUID? = id
        while let node = current {
            if !seen.insert(node).inserted { return true }
            current = resolvedParentID(groups.first { $0.id == node }?.parentID)
        }
        return false
    }

    private func applySiblingOrder(_ orderedIDs: [UUID], groupID: UUID?) {
        var remaining = projects
        var result: [Project] = []
        var siblingQueue = orderedIDs.compactMap { id in remaining.first { $0.id == id } }
        remaining.removeAll { isMember($0, of: groupID) }
        for project in projects {
            if isMember(project, of: groupID) {
                if let next = siblingQueue.first {
                    siblingQueue.removeFirst()
                    result.append(next)
                }
            } else if let idx = remaining.firstIndex(where: { $0.id == project.id }) {
                result.append(remaining.remove(at: idx))
            }
        }
        result.append(contentsOf: siblingQueue)
        result.append(contentsOf: remaining)
        projects = result
        reindexProjects()
    }

    private func isMember(_ project: Project, of groupID: UUID?) -> Bool {
        resolvedGroupID(project.groupID) == groupID
    }

    private func save() {
        guard !loadFailed else {
            logger.error("Refusing to save projects: prior load failed, file preserved")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(projects)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save projects: \(error, privacy: .public)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            logger.error("Failed to read projects file: \(error, privacy: .public)")
            loadFailed = true
            return
        }
        // An empty file is a genuine empty state, not corruption.
        guard !data.isEmpty else { return }
        do {
            projects = try JSONDecoder().decode([Project].self, from: data)
            projects.sort { $0.sortOrder < $1.sortOrder }
            // Migrate paths stored before normalization existed (e.g. with the
            // trailing slash `URL.path(percentEncoded:)` keeps on directories).
            // In-memory only; the cleaned form persists on the next mutation.
            for i in projects.indices {
                projects[i].path = ProjectPath.normalizedForStorage(projects[i].path)
            }
        } catch {
            // Present but undecodable — a corrupt entry or a future format.
            // Preserve the file: refuse to overwrite it until this session
            // restarts and reads it cleanly (or the user fixes it).
            logger.error("Failed to decode projects file: \(error, privacy: .public)")
            loadFailed = true
        }
    }

    private func saveGroups() {
        guard !groupsLoadFailed else {
            logger.error("Refusing to save project groups: prior load failed, file preserved")
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(groups)
            try data.write(to: groupsFileURL, options: .atomic)
        } catch {
            logger.error("Failed to save project groups: \(error, privacy: .public)")
        }
    }

    private func loadGroups() {
        guard FileManager.default.fileExists(atPath: groupsFileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: groupsFileURL)
        } catch {
            logger.error("Failed to read project groups file: \(error, privacy: .public)")
            groupsLoadFailed = true
            return
        }
        guard !data.isEmpty else { return }
        do {
            groups = try JSONDecoder().decode([ProjectGroup].self, from: data)
            groups.sort { $0.sortOrder < $1.sortOrder }
            breakGroupCycles()
        } catch {
            logger.error("Failed to decode project groups file: \(error, privacy: .public)")
            groupsLoadFailed = true
        }
    }
}
