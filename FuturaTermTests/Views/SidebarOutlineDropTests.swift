import AppKit
import Foundation
@testable import FuturaTerm
import Testing

struct SidebarOutlineDropTests {
    @Test
    func sibling_folder_insert_after_reorders() {
        let a = UUID()
        let b = UUID()
        let intent = SidebarDropIntent(
            target: .folder(b),
            kind: .insertAfter,
            indicator: .zero
        )
        let action = SidebarOutlineDrop.action(payload: .folder(a), intent: intent)
        #expect(action == .reorderFolder(a, onto: b, insertAfter: true))
    }

    @Test
    func folder_into_folder_nests() {
        let a = UUID()
        let b = UUID()
        let intent = SidebarDropIntent(target: .folder(b), kind: .into, indicator: .zero)
        #expect(
            SidebarOutlineDrop.action(payload: .folder(a), intent: intent)
                == .nestFolder(a, under: b)
        )
    }

    @Test
    func folder_onto_self_is_ignored() {
        let id = UUID()
        let intent = SidebarDropIntent(target: .folder(id), kind: .into, indicator: .zero)
        #expect(SidebarOutlineDrop.action(payload: .folder(id), intent: intent) == .ignore)
    }

    @Test
    func project_onto_folder_joins_that_folder() {
        let project = UUID()
        let folder = UUID()
        let intent = SidebarDropIntent(target: .folder(folder), kind: .into, indicator: .zero)
        #expect(
            SidebarOutlineDrop.action(payload: .project(project), intent: intent)
                == .projectJoinsFolder(project: project, folder: folder)
        )
    }

    @Test
    func project_insert_before_project_reorders() {
        let a = UUID()
        let b = UUID()
        let intent = SidebarDropIntent(
            target: .project(b),
            kind: .insertBefore,
            indicator: .zero
        )
        #expect(
            SidebarOutlineDrop.action(payload: .project(a), intent: intent)
                == .reorderProject(a, onto: b, insertAfter: false)
        )
    }

    @Test
    func intent_uses_folder_interior_as_into_and_edges_as_insert() {
        let folder = UUID()
        let project = UUID()
        let slots = [
            SidebarDropSlot(target: .folder(folder), frame: CGRect(x: 0, y: 0, width: 100, height: 20)),
            SidebarDropSlot(target: .project(project), frame: CGRect(x: 0, y: 80, width: 100, height: 20)),
        ]
        let into = SidebarOutlineDrop.intent(at: CGPoint(x: 10, y: 10), in: slots)
        #expect(into?.kind == .into)
        #expect(into?.target == .folder(folder))
        let before = SidebarOutlineDrop.intent(at: CGPoint(x: 10, y: 1), in: slots)
        #expect(before?.kind == .insertBefore)
        let after = SidebarOutlineDrop.intent(at: CGPoint(x: 10, y: 19), in: slots)
        #expect(after?.kind == .insertAfter)
        let projectOnRow = SidebarOutlineDrop.intent(at: CGPoint(x: 10, y: 88), in: slots)
        #expect(projectOnRow?.kind == .insertBefore)
        #expect(projectOnRow?.target == .project(project))
        let projectAfter = SidebarOutlineDrop.intent(at: CGPoint(x: 10, y: 98), in: slots)
        #expect(projectAfter?.kind == .insertAfter)
        #expect(projectAfter?.target == .project(project))
    }

    @Test
    func intent_above_the_first_row_is_insert_before_that_row() {
        let first = UUID()
        let second = UUID()
        let slots = [
            SidebarDropSlot(
                target: .project(first),
                frame: CGRect(x: 0, y: 40, width: 100, height: 22)
            ),
            SidebarDropSlot(
                target: .project(second),
                frame: CGRect(x: 0, y: 88, width: 100, height: 22)
            ),
        ]
        let above = SidebarOutlineDrop.intent(at: CGPoint(x: 12, y: 4), in: slots)
        #expect(above?.kind == .insertBefore)
        #expect(above?.target == .project(first))
        #expect(above?.indicator.minY == 38.5)
        let folder = UUID()
        let folderSlots = [
            SidebarDropSlot(
                target: .folder(folder),
                frame: CGRect(x: 0, y: 36, width: 100, height: 22)
            ),
        ]
        let aboveFolder = SidebarOutlineDrop.intent(at: CGPoint(x: 12, y: 0), in: folderSlots)
        #expect(aboveFolder?.kind == .insertBefore)
        #expect(aboveFolder?.target == .folder(folder))
    }

    @Test
    func json_payloads_round_trip_off_the_drag_pasteboard() throws {
        let folder = MovableFolder(groupID: UUID())
        let project = MovableProject(projectID: UUID())
        let folderData = try JSONEncoder().encode(folder)
        let projectData = try JSONEncoder().encode(project)
        let decodedFolder = try JSONDecoder().decode(MovableFolder.self, from: folderData)
        let decodedProject = try JSONDecoder().decode(MovableProject.self, from: projectData)
        #expect(decodedFolder.groupID == folder.groupID)
        #expect(decodedProject.projectID == project.projectID)
    }

    @Test
    func hit_bands_extend_each_header_down_to_the_next() {
        let a = UUID()
        let b = UUID()
        let slots = [
            SidebarDropSlot(target: .folder(a), frame: CGRect(x: 0, y: 0, width: 100, height: 20)),
            SidebarDropSlot(target: .project(b), frame: CGRect(x: 0, y: 80, width: 100, height: 20)),
        ]
        let bands = SidebarOutlineDrop.hitBands(for: slots)
        #expect(bands[0].frame.height == 80)
        #expect(SidebarOutlineDrop.slot(at: CGPoint(x: 10, y: 50), in: slots)?.target == .folder(a))
        #expect(SidebarOutlineDrop.slot(at: CGPoint(x: 10, y: 90), in: slots)?.target == .project(b))
    }

    @Test
    func payload_reads_folder_and_project_json_off_the_pasteboard() {
        let folderID = UUID()
        let projectID = UUID()
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString(
            "{\"groupID\":\"\(folderID.uuidString)\"}",
            forType: .string
        )
        #expect(SidebarOutlineDrop.payload(from: pasteboard) == .folder(folderID))
        pasteboard.clearContents()
        pasteboard.setString(
            "{\"projectID\":\"\(projectID.uuidString)\"}",
            forType: .string
        )
        #expect(SidebarOutlineDrop.payload(from: pasteboard) == .project(projectID))
    }
}
