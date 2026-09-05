import AppKit
@testable import FuturaTerm
import GhosttyKit
import Testing

/// Covers the terminal NSView contracts that do not require a live surface.
@MainActor
struct GhosttyTerminalNSViewTests {
    @Test
    func terminalSurface_exposesGhosttyAccessibilityContract() {
        let view = GhosttyTerminalNSView(
            paneID: UUID(),
            workingDirectory: "/tmp",
            sessionName: "accessibility-test"
        )

        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        #expect(view.accessibilityHelp() == "Terminal content area")
        #expect(view.accessibilityLabel() == "Terminal")
        #expect(view.accessibilityIdentifier() == view.paneID.uuidString)

        view.accessibilityTitleOverride = "zsh"
        #expect(view.accessibilityLabel() == "zsh")
        view.titleProvider = { "grok" }
        #expect(view.accessibilityLabel() == "grok")
        #expect(view.accessibilityHelp() == "Terminal content area")
        #expect((view.accessibilityValue() as? String)?.isEmpty == true)
        #expect(view.accessibilitySelectedTextRange() == NSRange())
        #expect(view.accessibilitySelectedText() == nil)
        #expect(view.accessibilityNumberOfCharacters() == 0)
        #expect(view.accessibilityVisibleCharacterRange() == NSRange())
        #expect(view.accessibilityChildren() == nil)
        #expect(view.accessibilityLine(for: 0) == 0)
        #expect(view.accessibilityRange(forLine: 0) == NSRange())
        #expect(view.accessibilityString(for: NSRange())?.isEmpty == true)
        #expect(view.accessibilityAttributedString(for: NSRange()) == nil)
        #expect(view.activateNumberedChoice(1) == false)
        view.setAccessibilitySelectedTextRange(NSRange(location: 0, length: 1))
        #expect(view.accessibilitySelectedTextRange() == NSRange())
        #expect(view.accessibilitySelectedText() == nil)
        #expect((view.accessibilityValue() as? String)?.isEmpty == true)
    }

    @Test
    func cursorMapping_coversTheShapesGhosttyEmits() {
        // The shapes the core actually sends over a terminal: text grid,
        // links, and TUI drag affordances.
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_TEXT) == NSCursor.iBeam)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_POINTER) == NSCursor.pointingHand)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_DEFAULT) == NSCursor.arrow)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_GRAB) == NSCursor.openHand)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_GRABBING) == NSCursor.closedHand)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_CROSSHAIR) == NSCursor.crosshair)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED) == NSCursor.operationNotAllowed)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_NS_RESIZE) != nil)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_EW_RESIZE) != nil)
    }

    @Test
    func cursorMapping_ignoresShapesWithNoMacOSCounterpart() {
        // Unknown → nil keeps the previous cursor, mirroring Ghostty.app.
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_ZOOM_IN) == nil)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_WAIT) == nil)
        #expect(GhosttyTerminalNSView.cursor(for: GHOSTTY_MOUSE_SHAPE_PROGRESS) == nil)
    }

    // MARK: - IME composition state

    private func makeView() -> GhosttyTerminalNSView {
        GhosttyTerminalNSView(
            paneID: UUID(),
            workingDirectory: "/tmp",
            sessionName: "marked-text-test"
        )
    }

    /// The mirror has to track AppKit's calls even with no surface attached —
    /// it used to be gated on one, so a composition begun before the surface
    /// existed read as not-composing.
    @Test
    func markedText_tracksCompositionWithoutASurface() {
        let view = makeView()
        #expect(!view.hasMarkedText())

        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 1))
    }

    /// `unmarkText` was gated on a surface too — the damaging direction, since
    /// a stranded range makes `keyDown` drop every unmodified key.
    @Test
    func markedText_unmarkClearsWithoutASurface() {
        let view = makeView()
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())

        view.unmarkText()

        #expect(!view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: NSNotFound, length: 0))
    }

    /// An empty commit is how some input sources abandon a composition, and it
    /// bailed out ahead of the clear.
    @Test
    func markedText_emptyCommitEndsTheComposition() {
        let view = makeView()
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())

        view.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(!view.hasMarkedText())
    }

    /// Focus leaving mid-composition is the path with no AppKit guarantee of an
    /// `unmarkText`, and the one that left a pane unable to type.
    @Test
    func markedText_focusLossAbandonsTheComposition() {
        let view = makeView()
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())

        _ = view.resignFirstResponder()

        #expect(!view.hasMarkedText())
    }

    /// A destroyed surface has nowhere to commit, so the preedit must not
    /// outlive it into a reattached surface.
    @Test
    func markedText_surfaceTeardownAbandonsTheComposition() {
        let view = makeView()
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())

        view.destroySurface()

        #expect(!view.hasMarkedText())
    }

    // MARK: - Programmatic selection

    @Test
    func selectAPIs_returnFalseWithoutASurface() {
        let view = makeView()
        #expect(view.surface == nil)
        #expect(view.selectText(range: NSRange(location: 0, length: 1)) == false)
        #expect(view.selectCells(start: (1, 1), end: (2, 1)) == false)
        #expect(view.selectCells(start: (0, 1), end: (1, 1)) == false)
        #expect(view.selectCells(start: (99, 99), end: (99, 99)) == false)
        #expect(view.clickCell(col: 1, row: 1) == false)
        #expect(view.accessibilityChildren() == nil)
        #expect((view.accessibilityValue() as? String)?.isEmpty == true)
        #expect(view.accessibilitySelectedTextRange() == NSRange())
        #expect(view.accessibilitySelectedText() == nil)
    }

    @Test
    func selectionMapping_rangeCoveringCd_mapsToSecondRowCells() throws {
        let text = "ab\ncd\n"
        let range = (text as NSString).range(of: "cd")
        #expect(range.location == 3)
        #expect(range.length == 2)

        let cells = try #require(TerminalSelectionMapping.cells(for: range, in: text))
        #expect(cells.start.col == 1)
        #expect(cells.start.row == 2)
        #expect(cells.end.col == 2)
        #expect(cells.end.row == 2)
    }

    @Test
    func selectionMapping_firstRowAndEmptyRange() throws {
        let text = "ab\ncd\n"
        let ab = try #require(TerminalSelectionMapping.cells(
            for: (text as NSString).range(of: "ab"),
            in: text
        ))
        #expect(ab.start.col == 1)
        #expect(ab.start.row == 1)
        #expect(ab.end.col == 2)
        #expect(ab.end.row == 1)

        let cRange = (text as NSString).range(of: "c")
        #expect(cRange.location == 3)
        #expect(cRange.length == 1)
        let c = try #require(TerminalSelectionMapping.cells(for: cRange, in: text))
        #expect(c.start.col == 1)
        #expect(c.start.row == 2)
        #expect(c.end.col == 1)
        #expect(c.end.row == 2)

        let caretOnC = try #require(TerminalSelectionMapping.cells(
            for: NSRange(location: 3, length: 0),
            in: text
        ))
        #expect(caretOnC.start.col == 1)
        #expect(caretOnC.start.row == 2)
        #expect(caretOnC.end.col == 1)
        #expect(caretOnC.end.row == 2)
        #expect(cRange.length != 0)

        let caretOnNewline = try #require(TerminalSelectionMapping.cells(
            for: NSRange(location: 2, length: 0),
            in: text
        ))
        #expect(caretOnNewline.start.col == 2)
        #expect(caretOnNewline.start.row == 1)
        #expect(caretOnNewline.end.col == 2)
        #expect(caretOnNewline.end.row == 1)
    }

    @Test
    func selectionMapping_outOfRangeAndEmptyText_returnNil() {
        let text = "ab\ncd\n"
        #expect(TerminalSelectionMapping.cells(for: NSRange(location: 99, length: 1), in: text) == nil)
        #expect(TerminalSelectionMapping.cells(for: NSRange(location: 0, length: 99), in: text) == nil)
        #expect(TerminalSelectionMapping.cells(
            for: NSRange(location: NSNotFound, length: 0),
            in: text
        ) == nil)
        #expect(TerminalSelectionMapping.cells(for: NSRange(location: 2, length: 1), in: text) == nil)
        #expect(TerminalSelectionMapping.cells(for: NSRange(location: 0, length: 0), in: "") == nil)
        #expect(TerminalSelectionMapping.cells(for: NSRange(location: 0, length: 1), in: "") == nil)
    }

    @Test
    func selectionMapping_mousePoint_centersValidCellsAndRejectsOutOfRange() throws {
        let grid = (columns: 2, rows: 2)
        let cellSize = (width: CGFloat(10), height: CGFloat(20))
        let pt = try #require(TerminalSelectionMapping.mousePoint(
            cell: (1, 1),
            grid: grid,
            cellSize: cellSize
        ))
        #expect(pt.x == 5)
        #expect(pt.y == 10)

        let bottomRight = try #require(TerminalSelectionMapping.mousePoint(
            cell: (2, 2),
            grid: grid,
            cellSize: cellSize
        ))
        #expect(bottomRight.x == 15)
        #expect(bottomRight.y == 30)

        let offDiagonal = try #require(TerminalSelectionMapping.mousePoint(
            cell: (2, 1),
            grid: grid,
            cellSize: cellSize
        ))
        #expect(offDiagonal.x == 15)
        #expect(offDiagonal.y == 10)

        let otherOffDiagonal = try #require(TerminalSelectionMapping.mousePoint(
            cell: (1, 2),
            grid: grid,
            cellSize: cellSize
        ))
        #expect(otherOffDiagonal.x == 5)
        #expect(otherOffDiagonal.y == 30)

        #expect(TerminalSelectionMapping.mousePoint(cell: (0, 1), grid: grid, cellSize: cellSize) == nil)
        #expect(TerminalSelectionMapping.mousePoint(cell: (99, 99), grid: grid, cellSize: cellSize) == nil)
        #expect(TerminalSelectionMapping.mousePoint(
            cell: (1, 1),
            grid: grid,
            cellSize: (0, 20)
        ) == nil)
        #expect(TerminalSelectionMapping.mousePoint(
            cell: (1, 1),
            grid: (0, 2),
            cellSize: cellSize
        ) == nil)
    }

    @Test
    func selectionMapping_oneCellSelectDragsEdges_clickUsesCenter() throws {
        let grid = (columns: 2, rows: 2)
        let cellSize = (width: CGFloat(10), height: CGFloat(20))
        let select = try #require(TerminalSelectionMapping.dragPoints(
            from: (1, 1),
            to: (1, 1),
            grid: grid,
            cellSize: cellSize,
            kind: .select
        ))
        #expect(select.start.x == 0)
        #expect(select.end.x == 10)
        #expect(select.start.x != select.end.x)
        #expect(select.start.y == 10)
        #expect(select.end.y == 10)

        let click = try #require(TerminalSelectionMapping.dragPoints(
            from: (1, 1),
            to: (1, 1),
            grid: grid,
            cellSize: cellSize,
            kind: .click
        ))
        #expect(click.start.x == 5)
        #expect(click.end.x == 5)
        #expect(click.start.x == click.end.x)
        #expect(click.start.x != select.start.x)
        #expect(click.end.x != select.end.x)

        let reverse = try #require(TerminalSelectionMapping.dragPoints(
            from: (2, 1),
            to: (1, 1),
            grid: grid,
            cellSize: cellSize,
            kind: .select
        ))
        #expect(reverse.start.x == 20)
        #expect(reverse.end.x == 0)
    }

    @Test
    func accessibilityText_mapsLinesOnViewportString() {
        let text = "ab\ncd\n"
        #expect(TerminalAccessibilityText.utf16Count(text) == 6)
        #expect(TerminalAccessibilityText.line(for: 0, in: text) == 0)
        #expect(TerminalAccessibilityText.line(for: 2, in: text) == 0)
        #expect(TerminalAccessibilityText.line(for: 3, in: text) == 1)
        #expect(TerminalAccessibilityText.range(forLine: 0, in: text) == NSRange(location: 0, length: 3))
        #expect(TerminalAccessibilityText.range(forLine: 1, in: text) == NSRange(location: 3, length: 3))
        #expect(TerminalAccessibilityText.range(forLine: 2, in: text) == NSRange(location: 6, length: 0))
        #expect(TerminalAccessibilityText.range(forLine: 3, in: text) == NSRange())
        #expect(TerminalAccessibilityText.string(for: NSRange(location: 3, length: 2), in: text) == "cd")
        #expect(TerminalAccessibilityText.line(for: 0, in: "") == 0)
        #expect(TerminalAccessibilityText.range(forLine: 0, in: "") == NSRange())
    }

    @Test
    func accessibilityText_convertsScreenSelectionOntoViewportSuffix() {
        let screen = "xx\nab\ncd\n"
        let viewport = "ab\ncd\n"
        let range = (screen as NSString).range(of: "cd")
        let converted = TerminalAccessibilityText.viewportSelection(
            screenRange: range,
            viewport: viewport,
            screen: screen
        )
        #expect(converted == (viewport as NSString).range(of: "cd"))

        let historyOnly = TerminalAccessibilityText.viewportSelection(
            screenRange: NSRange(location: 0, length: 2),
            viewport: viewport,
            screen: screen
        )
        #expect(historyOnly == NSRange())

        let wholeScreen = TerminalAccessibilityText.viewportSelection(
            screenRange: NSRange(location: 0, length: (screen as NSString).length),
            viewport: viewport,
            screen: screen
        )
        #expect(wholeScreen == NSRange(location: 0, length: (viewport as NSString).length))
    }

    @Test
    func numberedChoiceAX_buildsButtonsWithTitlesAndPressSendsDigitThenReturn() {
        let view = makeView()
        let contents = """
        What would you like to do?

        1. Continue
        2. Always allow this command
        """
        var activations: [(text: String, keyCode: UInt16, mods: NSEvent.ModifierFlags)] = []
        view.numberedChoiceActivationHandler = { text, keyCode, mods in
            activations.append((text, keyCode, mods))
            return true
        }
        let elements = view.makeNumberedChoiceAXElements(from: contents)

        #expect(elements.count == 2)
        #expect(elements.map { $0.accessibilityRole() } == [.button, .button])
        #expect(elements.map { $0.accessibilityTitle() } == [
            "1. Continue",
            "2. Always allow this command",
        ])
        #expect(elements.map { $0.accessibilityLabel() } == [
            "1. Continue",
            "2. Always allow this command",
        ])
        #expect(elements[0].accessibilityHelp() == "Terminal choice 1")
        #expect(elements[1].accessibilityHelp() == "Terminal choice 2")
        #expect(elements[0].accessibilityParent() as? GhosttyTerminalNSView === view)
        #expect(elements[0].accessibilityFrame() == .zero)

        #expect(elements[0].accessibilityPerformPress())
        #expect(elements[1].accessibilityPerformPress())
        let ret = HotkeyRegistry.parseShortcut("return")
        #expect(activations.map(\.text) == ["1", "2"])
        #expect(activations.allSatisfy { $0.keyCode == ret?.keyCode && $0.mods == ret?.modifiers })
    }

    @Test
    func numberedChoiceAX_childrenReuseIdentityWhenViewportAndRowsAreUnchanged() throws {
        let view = makeView()
        let menu = """
        1. Continue
        2. Always allow this command
        """
        view.accessibilityViewportOverride = menu
        let first = try #require(view.accessibilityChildren()?.compactMap { $0 as? NumberedChoiceAXElement })
        #expect(first.count == 2)
        #expect(first.map { $0.accessibilityTitle() } == [
            "1. Continue",
            "2. Always allow this command",
        ])

        view.surfaceDidOutputActivity(total: 10, offset: 0, len: 10)
        let afterHeartbeat = try #require(view.accessibilityChildren()?.compactMap { $0 as? NumberedChoiceAXElement })
        #expect(afterHeartbeat.count == 2)
        #expect(afterHeartbeat[0] === first[0])
        #expect(afterHeartbeat[1] === first[1])

        view.accessibilityViewportOverride = menu + "\n\nstatus ok"
        view.surfaceDidChangeSelection()
        let afterUnrelatedDump = try #require(view.accessibilityChildren()?.compactMap { $0 as? NumberedChoiceAXElement })
        #expect(afterUnrelatedDump[0] === first[0])
        #expect(afterUnrelatedDump[1] === first[1])

        view.accessibilityViewportOverride = """
        1. Continue
        2. Stop
        """
        view.surfaceDidOutputActivity(total: 11, offset: 0, len: 11)
        let afterRowsChange = try #require(view.accessibilityChildren()?.compactMap { $0 as? NumberedChoiceAXElement })
        #expect(afterRowsChange.count == 2)
        #expect(afterRowsChange[0] !== first[0])
        #expect(afterRowsChange.map { $0.accessibilityTitle() } == ["1. Continue", "2. Stop"])
    }

    @Test
    func numberedChoiceAX_emptyDumpHasNoChildren() {
        let view = makeView()
        view.accessibilityViewportOverride = "no menu here\njust prose"
        #expect(view.accessibilityChildren() == nil)
        #expect(view.makeNumberedChoiceAXElements(from: "1. foo").isEmpty)
    }

    @Test
    func paneSelection_getOffsetsMatchSelectTextViewportUnit() {
        // GET `pane.selection` maps screen UTF-16 onto the viewport so SET
        // `--start/--length` can round-trip (scrollback-only → empty).
        let screen = "hist\nab\ncd\n"
        let viewport = "ab\ncd\n"
        let screenRange = (screen as NSString).range(of: "cd")
        let viewportRange = TerminalAccessibilityText.viewportSelection(
            screenRange: screenRange,
            viewport: viewport,
            screen: screen
        )
        #expect(viewportRange == (viewport as NSString).range(of: "cd"))
        #expect(TerminalSelectionMapping.cells(for: viewportRange, in: viewport) != nil)

        let history = TerminalAccessibilityText.viewportSelection(
            screenRange: NSRange(location: 0, length: 4),
            viewport: viewport,
            screen: screen
        )
        #expect(history.length == 0)
    }
}
