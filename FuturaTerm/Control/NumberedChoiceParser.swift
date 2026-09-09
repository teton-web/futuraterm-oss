import Foundation

/// One numbered TUI menu row inferred from viewport dump text.
///
/// `line` / `column` are 1-based in that text so a later `pane click` can
/// target the first digit. `column` counts Unicode scalars from the start of
/// the line (libghostty dump text is already cell-shaped for ASCII + BMP
/// markers such as `❯`).
struct NumberedChoice: Equatable {
    var index: Int
    var label: String
    var line: Int
    var column: Int
    var selected: Bool
}

/// Pure scan of pane dump text for a consecutive numbered-choice run.
///
/// Isolated `N. rest` lines and prose such as "see step 1." are not menus —
/// a run must be at least two consecutive indexes. A run that includes a
/// selection marker beats a longer unmarked numbered plan (viewport: plan
/// above, `❯ 1.` menu below). Unmarked dumps still pick longest, then
/// start-at-1 on a length tie.
enum NumberedChoiceParser {
    /// Ticket marker set. Presence, not which glyph, sets `selected` — `o` is
    /// selected here, not an unselected radio.
    private static let selectionMarkers: Set<Character> = [">", "❯", "*", "•", "o"]

    static func parse(_ text: String) -> [NumberedChoice] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var candidates: [NumberedChoice] = []
        candidates.reserveCapacity(lines.count)
        for (offset, line) in lines.enumerated() {
            if let choice = match(line, lineNumber: offset + 1) {
                candidates.append(choice)
            }
        }
        return winningRun(in: candidates)
    }

    /// Marked run first (start-at-1, then longest, then earliest). Else longest
    /// unmarked, start-at-1 on a length tie, then earliest.
    private static func winningRun(in candidates: [NumberedChoice]) -> [NumberedChoice] {
        let runs = consecutiveIndexRuns(in: candidates).filter { $0.count >= 2 }
        guard !runs.isEmpty else { return [] }
        let marked = runs.filter { $0.contains(where: \.selected) }
        if !marked.isEmpty {
            return pickRun(marked, preferStartAtOneFirst: true)
        }
        return pickRun(runs, preferStartAtOneFirst: false)
    }

    private static func pickRun(_ runs: [[NumberedChoice]], preferStartAtOneFirst: Bool) -> [NumberedChoice] {
        var pool = runs
        if preferStartAtOneFirst, runs.contains(where: startsAtOne) {
            pool = runs.filter(startsAtOne)
        }
        let longest = pool.map(\.count).max() ?? 0
        let tied = pool.filter { $0.count == longest }
        if !preferStartAtOneFirst, let startAtOne = tied.first(where: startsAtOne) {
            return startAtOne
        }
        return tied[0]
    }

    private static func startsAtOne(_ run: [NumberedChoice]) -> Bool {
        run.first?.index == 1
    }

    /// Splits on any index that is not exactly one more than the previous
    /// candidate. Intervening non-matching dump lines do not break a run;
    /// a missing number (1 then 3) does. `Int.max` does not overflow `+ 1`.
    private static func consecutiveIndexRuns(in candidates: [NumberedChoice]) -> [[NumberedChoice]] {
        guard var previous = candidates.first else { return [] }
        var runs: [[NumberedChoice]] = []
        var current = [previous]
        for choice in candidates.dropFirst() {
            if previous.index < Int.max, choice.index == previous.index + 1 {
                current.append(choice)
            } else {
                runs.append(current)
                current = [choice]
            }
            previous = choice
        }
        runs.append(current)
        return runs
    }

    /// `N. rest` / `N) rest` at line start after optional indent and marker.
    /// Indent is space/tab only — box-drawing (`│`) is left unmatched until a
    /// dump shows grok wrapping menus that way.
    /// Empty labels (no non-whitespace after the delimiter) are not choices.
    private static func match(_ raw: Substring, lineNumber: Int) -> NumberedChoice? {
        let line = trimTrailingWhitespace(raw)
        var index = line.startIndex
        let end = line.endIndex

        skipASCIISpaces(in: line, index: &index)

        var selected = false
        if index < end, selectionMarkers.contains(line[index]) {
            selected = true
            line.formIndex(after: &index)
            skipASCIISpaces(in: line, index: &index)
        }

        guard index < end, isASCIIDigit(line[index]), line[index] != "0" else { return nil }
        let digitStart = index
        var digits = String()
        while index < end, isASCIIDigit(line[index]) {
            digits.append(line[index])
            line.formIndex(after: &index)
        }
        guard let choiceIndex = Int(digits), choiceIndex > 0 else { return nil }

        guard index < end, line[index] == "." || line[index] == ")" else { return nil }
        line.formIndex(after: &index)
        guard index < end, isASCIISpace(line[index]) else { return nil }
        skipASCIISpaces(in: line, index: &index)
        guard index < end else { return nil }

        let label = String(line[index...]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }

        let column = line.distance(from: line.startIndex, to: digitStart) + 1
        return NumberedChoice(
            index: choiceIndex,
            label: label,
            line: lineNumber,
            column: column,
            selected: selected
        )
    }

    private static func trimTrailingWhitespace(_ raw: Substring) -> Substring {
        var end = raw.endIndex
        while end > raw.startIndex {
            let previous = raw.index(before: end)
            guard raw[previous].isWhitespace else { break }
            end = previous
        }
        return raw[..<end]
    }

    private static func skipASCIISpaces(in line: Substring, index: inout Substring.Index) {
        while index < line.endIndex, isASCIISpace(line[index]) {
            line.formIndex(after: &index)
        }
    }

    private static func isASCIISpace(_ ch: Character) -> Bool {
        ch == " " || ch == "\t"
    }

    private static func isASCIIDigit(_ ch: Character) -> Bool {
        ch >= "0" && ch <= "9"
    }
}
