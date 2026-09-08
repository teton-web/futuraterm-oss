import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: appBundleID, category: "SidebarOutlineDrop")

extension NSPasteboard.PasteboardType {
    static let futuraTermProjectMove = NSPasteboard.PasteboardType(UTType.futuraTermProject.identifier)
    static let futuraTermFolderMove = NSPasteboard.PasteboardType(UTType.futuraTermFolder.identifier)
}

/// A folder or project header's frame in the sidebar **outline** coordinate
/// space (the same space `NSOutlineView.convert` uses for a drag).
struct SidebarDropSlot: Equatable {
    enum Target: Equatable, Hashable {
        case folder(UUID)
        case project(UUID)
    }

    var target: Target
    var frame: CGRect
}

/// Live drop feedback: a source-list insertion line, or a Finder-style
/// "drop into this folder" fill.
struct SidebarDropIntent: Equatable {
    enum Kind: Equatable {
        case insertBefore
        case insertAfter
        case into
    }

    var target: SidebarDropSlot.Target
    var kind: Kind
    /// Line (insert) or row (into) in outline coordinate space.
    var indicator: CGRect
}

/// Payload and routing for top-level sidebar reordering (folders and
/// projects). Tab/pane drags stay on the nested ForEach insertion line.
enum SidebarOutlineDrop {
    enum Payload: Equatable {
        case folder(UUID)
        case project(UUID)
    }

    enum Action: Equatable {
        case reorderFolder(UUID, onto: UUID, insertAfter: Bool)
        case nestFolder(UUID, under: UUID)
        case folderJoinsProjectGroup(folder: UUID, project: UUID)
        case projectJoinsFolder(project: UUID, folder: UUID)
        case reorderProject(UUID, onto: UUID, insertAfter: Bool)
        case ignore
    }

    static func action(
        payload: Payload,
        intent: SidebarDropIntent
    ) -> Action {
        switch (payload, intent.kind, intent.target) {
        case let (.folder(id), .into, .folder(dest)):
            guard id != dest else { return .ignore }
            return .nestFolder(id, under: dest)
        case let (.folder(id), .insertBefore, .folder(dest)):
            guard id != dest else { return .ignore }
            return .reorderFolder(id, onto: dest, insertAfter: false)
        case let (.folder(id), .insertAfter, .folder(dest)):
            guard id != dest else { return .ignore }
            return .reorderFolder(id, onto: dest, insertAfter: true)
        case let (.folder(id), _, .project(projectID)):
            return .folderJoinsProjectGroup(folder: id, project: projectID)
        case let (.project(id), _, .folder(folderID)):
            return .projectJoinsFolder(project: id, folder: folderID)
        case let (.project(id), .insertBefore, .project(dest)):
            guard id != dest else { return .ignore }
            return .reorderProject(id, onto: dest, insertAfter: false)
        case let (.project(id), .insertAfter, .project(dest)):
            guard id != dest else { return .ignore }
            return .reorderProject(id, onto: dest, insertAfter: true)
        case (.project, .into, .project):
            return .ignore
        }
    }

    static func payload(from pasteboard: NSPasteboard) -> Payload? {
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                let data = item.data(forType: type) ?? item.string(forType: type)?.data(using: .utf8)
                guard let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let raw = object["groupID"] as? String, let id = UUID(uuidString: raw) {
                    return .folder(id)
                }
                if let raw = object["projectID"] as? String, let id = UUID(uuidString: raw) {
                    return .project(id)
                }
            }
        }
        return nil
    }

    static func pasteboardHasOutlinePayload(_ pasteboard: NSPasteboard) -> Bool {
        payload(from: pasteboard) != nil
    }

    /// Stretch each header's hit band down to the next header so a drop on
    /// that project's tabs still targets the project, not empty space.
    static func hitBands(for slots: [SidebarDropSlot]) -> [SidebarDropSlot] {
        let sorted = slots.sorted { $0.frame.minY < $1.frame.minY }
        return sorted.enumerated().map { index, slot in
            var frame = slot.frame
            let nextMinY = index + 1 < sorted.count ? sorted[index + 1].frame.minY : frame.maxY
            frame.size.height = max(frame.height, nextMinY - frame.minY)
            return SidebarDropSlot(target: slot.target, frame: frame)
        }
    }

    static func slot(at point: CGPoint, in slots: [SidebarDropSlot]) -> SidebarDropSlot? {
        let bands = hitBands(for: slots)
        if let hit = bands.first(where: { $0.frame.contains(point) }) {
            return hit
        }
        return bands.min { abs($0.frame.midY - point.y) < abs($1.frame.midY - point.y) }
    }

    /// Finder/source-list targeting: folder interior is "drop into"; the
    /// top/bottom edges (and project rows) are an insertion line.
    static func intent(at point: CGPoint, in slots: [SidebarDropSlot]) -> SidebarDropIntent? {
        let sorted = slots.sorted { $0.frame.minY < $1.frame.minY }
        guard !sorted.isEmpty else { return nil }
        if point.y < sorted[0].frame.minY {
            return makeIntent(
                slot: sorted[0],
                kind: .insertBefore,
                lineY: sorted[0].frame.minY
            )
        }
        let bands = hitBands(for: sorted)
        let index: Int
        if let i = bands.firstIndex(where: { $0.frame.contains(point) }) {
            index = i
        } else if let nearest = bands.enumerated().min(by: {
            abs($0.element.frame.midY - point.y) < abs($1.element.frame.midY - point.y)
        }) {
            index = nearest.offset
        } else {
            return nil
        }
        let slot = sorted[index]
        let header = slot.frame
        let nextMinY = index + 1 < sorted.count ? sorted[index + 1].frame.minY : header.maxY
        let edge = min(max(header.height * 0.3, 6), 14)
        let kind: SidebarDropIntent.Kind
        let lineY: CGFloat
        switch slot.target {
        case .folder:
            if point.y > header.maxY {
                kind = .into
                lineY = header.midY
            } else if point.y < header.minY + edge {
                kind = .insertBefore
                lineY = header.minY
            } else if point.y > header.maxY - edge {
                kind = .insertAfter
                lineY = nextMinY > header.maxY + 2 ? (header.maxY + nextMinY) / 2 : header.maxY
            } else {
                kind = .into
                lineY = header.midY
            }
        case .project:
            // Most of the row is "land here" (insert before this row). Only
            // the bottom edge / gap is insert-after — using midY made the
            // line sit on the next row for a pointer aimed at this one.
            if point.y > header.maxY - edge {
                kind = .insertAfter
                lineY = nextMinY > header.maxY + 2 ? (header.maxY + nextMinY) / 2 : header.maxY
            } else {
                kind = .insertBefore
                lineY = header.minY
            }
        }
        return makeIntent(slot: slot, kind: kind, lineY: lineY)
    }

    private static func makeIntent(
        slot: SidebarDropSlot,
        kind: SidebarDropIntent.Kind,
        lineY: CGFloat
    ) -> SidebarDropIntent {
        let header = slot.frame
        let indicator: CGRect = if kind == .into {
            header.insetBy(dx: 4, dy: 1)
        } else {
            CGRect(x: header.minX + 10, y: lineY - 1.5, width: max(header.width - 20, 16), height: 3)
        }
        return SidebarDropIntent(target: slot.target, kind: kind, indicator: indicator)
    }
}

/// Invisible probe in a folder/project header. Its AppKit frame is converted
/// into the outline on each drag, so hit-testing and the insertion line share
/// one space — mixing SwiftUI List-named frames with outline-document points
/// put the line several rows below the pointer.
struct SidebarDropSlotReporter: View {
    let target: SidebarDropSlot.Target

    var body: some View {
        GeometryReader { proxy in
            SidebarDropSlotProbe(target: target)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
        }
    }
}

private struct SidebarDropSlotProbe: NSViewRepresentable {
    var target: SidebarDropSlot.Target

    func makeNSView(context _: Context) -> SidebarDropSlotProbeView {
        let view = SidebarDropSlotProbeView()
        view.target = target
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: SidebarDropSlotProbeView, context _: Context) {
        view.target = target
    }
}

final class SidebarDropSlotProbeView: NSView {
    var target: SidebarDropSlot.Target?

    override var isOpaque: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

/// Invisible hook in the SwiftUI tree that reparents a real AppKit catcher
/// as a sibling *above* the sidebar `NSOutlineView`.
///
/// A SwiftUI `.overlay` over the `List` sits in front of every row and eats
/// clicks (even when `hitTest` returns nil — the hosting view still claims
/// the point). A 0×0 hook does not. The catcher is an AppKit sibling of the
/// outline: clicks miss it (`hitTest` returns nil unless a folder/project
/// drag is in flight), so they reach the list; folder/project drags hit it
/// before the outline can crash in `acceptDrop`.
///
/// The insertion line is drawn on the catcher in outline space. Do not put
/// it in a SwiftUI overlay: that space is not the outline's, and publishing
/// it on every mouse-move rebuilds the List mid-drag.
struct SidebarOutlineDropCatcher: NSViewRepresentable {
    var onIntent: (SidebarDropIntent?) -> Void
    var onDrop: (SidebarOutlineDrop.Payload, SidebarDropIntent) -> Bool

    func makeNSView(context _: Context) -> HookView {
        let hook = HookView()
        configure(hook)
        return hook
    }

    func updateNSView(_ hook: HookView, context _: Context) {
        configure(hook)
        hook.installIfNeeded()
    }

    private func configure(_ hook: HookView) {
        hook.catcher.onIntent = onIntent
        hook.catcher.onDrop = onDrop
    }

    final class HookView: NSView {
        let catcher = CatcherView()

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                catcher.removeFromSuperview()
            } else {
                installIfNeeded()
            }
        }

        func installIfNeeded() {
            guard let outline = findSidebarOutline(), let parent = outline.superview else { return }
            if catcher.superview !== parent {
                catcher.removeFromSuperview()
                parent.addSubview(catcher, positioned: .above, relativeTo: outline)
            }
            catcher.outlineView = outline
            catcher.frame = outline.frame
            catcher.autoresizingMask = [.width, .height]
        }

        private func findSidebarOutline() -> NSOutlineView? {
            var ancestor: NSView? = self
            var root: NSView = self
            while let current = ancestor {
                if let outline = current as? NSOutlineView { return outline }
                root = current
                ancestor = current.superview
            }
            return root.firstOutlineView()
        }
    }

    final class CatcherView: NSView {
        var onIntent: (SidebarDropIntent?) -> Void = { _ in }
        var onDrop: (SidebarOutlineDrop.Payload, SidebarDropIntent) -> Bool = { _, _ in false }
        weak var outlineView: NSOutlineView?
        private var claimingDrag = false
        private var drawnIntent: SidebarDropIntent?
        private var publishedKind: SidebarDropIntent.Kind?
        private var publishedTarget: SidebarDropSlot.Target?

        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([
                .futuraTermProjectMove,
                .futuraTermFolderMove,
                NSPasteboard.PasteboardType("public.json"),
            ])
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        /// Default is miss: this view is in front of the outline. Only an
        /// in-flight folder/project drag (not leftover pasteboard, not a
        /// click) may land here.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            if claimingDrag { return self }
            guard NSApp.currentEvent?.type == .leftMouseDragged,
                  SidebarOutlineDrop.pasteboardHasOutlinePayload(NSPasteboard(name: .drag))
            else { return nil }
            return self
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            claimingDrag = true
            return draggingUpdated(sender)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard let intent = intent(under: sender) else {
                publish(nil)
                return []
            }
            publish(intent)
            return .move
        }

        override func draggingExited(_: (any NSDraggingInfo)?) {
            claimingDrag = false
            publish(nil)
        }

        override func draggingEnded(_: any NSDraggingInfo) {
            claimingDrag = false
            publish(nil)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer {
                claimingDrag = false
                publish(nil)
            }
            guard let payload = SidebarOutlineDrop.payload(from: sender.draggingPasteboard) else {
                logger.debug("outline drop: no folder/project payload on pasteboard")
                return false
            }
            guard let intent = intent(under: sender) else { return false }
            return onDrop(payload, intent)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let intent = drawnIntent else { return }
            let rect = indicatorRect(for: intent)
            let accent = NSColor.controlAccentColor
            if intent.kind == .into {
                let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                accent.withAlphaComponent(0.16).setFill()
                path.fill()
                accent.withAlphaComponent(0.55).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                let dot = NSRect(x: rect.minX, y: rect.midY - 3.5, width: 7, height: 7)
                accent.setFill()
                NSBezierPath(ovalIn: dot).fill()
                let line = NSRect(
                    x: rect.minX + 6,
                    y: rect.midY - 1.25,
                    width: max(rect.width - 6, 8),
                    height: 2.5
                )
                NSBezierPath(roundedRect: line, xRadius: 1.25, yRadius: 1.25).fill()
            }
        }

        private func intent(under sender: any NSDraggingInfo) -> SidebarDropIntent? {
            syncFrameToOutline()
            let point = dropPoint(from: sender)
            return SidebarOutlineDrop.intent(at: point, in: liveSlots())
        }

        private func dropPoint(from sender: any NSDraggingInfo) -> CGPoint {
            if let outline = outlineView {
                return outline.convert(sender.draggingLocation, from: nil)
            }
            return convert(sender.draggingLocation, from: nil)
        }

        /// Header frames in outline space, taken from probes sitting in those
        /// rows — not from SwiftUI named-space GeometryReaders.
        private func liveSlots() -> [SidebarDropSlot] {
            guard let outline = outlineView else { return [] }
            let root: NSView = outline.enclosingScrollView ?? outline
            var byTarget: [SidebarDropSlot.Target: CGRect] = [:]
            for probe in probeViews(in: root) {
                guard let target = probe.target else { continue }
                let frame = probe.convert(probe.bounds, to: outline)
                guard frame.width >= 1, frame.height >= 1 else { continue }
                byTarget[target] = frame
            }
            if byTarget.isEmpty {
                logger.debug("outline drop: no header probes in the outline")
            }
            return byTarget.map { SidebarDropSlot(target: $0.key, frame: $0.value) }
        }

        private func probeViews(in view: NSView) -> [SidebarDropSlotProbeView] {
            var result: [SidebarDropSlotProbeView] = []
            if let probe = view as? SidebarDropSlotProbeView {
                result.append(probe)
            }
            for child in view.subviews {
                result.append(contentsOf: probeViews(in: child))
            }
            return result
        }

        private func syncFrameToOutline() {
            guard let outline = outlineView else { return }
            if frame != outline.frame {
                frame = outline.frame
            }
        }

        private func indicatorRect(for intent: SidebarDropIntent) -> CGRect {
            guard let outline = outlineView else { return intent.indicator }
            return convert(intent.indicator, from: outline)
        }

        /// Draw locally on every move. Tell SwiftUI only when the *target*
        /// changes (spring-open) — publishing the line rect each tick rebuilt
        /// the List and cancelled/jittered the drag.
        private func publish(_ intent: SidebarDropIntent?) {
            drawnIntent = intent
            needsDisplay = true
            let kind = intent?.kind
            let target = intent?.target
            if kind != publishedKind || target != publishedTarget {
                publishedKind = kind
                publishedTarget = target
                onIntent(intent)
            }
        }
    }
}

private extension NSView {
    func firstOutlineView() -> NSOutlineView? {
        if let outline = self as? NSOutlineView { return outline }
        for child in subviews {
            if let outline = child.firstOutlineView() { return outline }
        }
        return nil
    }
}
