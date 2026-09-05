import Foundation

/// Named folder grouping projects in the sidebar. Folders may nest up to
/// `ProjectStore.maxFolderDepth` (root depth = 1). Not a filesystem folder
/// and not a `ProjectStore` row — workspaces stay keyed by `Project.id`.
/// Membership of **projects** lives on `Project.groupID` (the folder they
/// sit in, not the ancestor chain).
struct ProjectGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var sortOrder: Int
    /// Parent folder. nil = root. Absent key on disk decodes as nil.
    var parentID: UUID?

    init(name: String, sortOrder: Int = 0, parentID: UUID? = nil) {
        id = UUID()
        self.name = name
        self.sortOrder = sortOrder
        self.parentID = parentID
    }

    init(id: UUID, name: String, sortOrder: Int, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.parentID = parentID
    }
}
