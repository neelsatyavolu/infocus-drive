import Foundation

/// A class day's or a holiday's notes, edited without losing what the Portal's rich editor wrote.
///
/// The cell (after the hide-image token) is split into its top-level blocks. Runs of plain
/// paragraphs are editable text; a paragraph holding only a package pill is a pill; anything else
/// (bold, italics, underline, lists, a pill inside a sentence) is kept byte for byte and shown
/// read-only. An untouched block is written back exactly as it was read, so a save changes only
/// what was edited on the phone. Pill renames and removals use the Portal's own HTML edits
/// (`renamePillInHtml`, `removePillFromHtml` in components/master-calendar/calendar-model.ts).
struct CalendarNotesDocument: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        /// Plain paragraphs as lines ("" for an empty paragraph); `original` is the HTML they came
        /// from, written back unchanged while `text == originalText`.
        case text(text: String, original: String, originalText: String)
        case pill(CalendarNotes.Pill, original: String)
        /// Formatted HTML, never rewritten except by pill renames and removals.
        case rich(String)
    }

    private(set) var blocks: [Block]
    /// The body as loaded (no image token).
    let originalBody: String

    var isDirty: Bool { body() != originalBody }
    var hasFormatting: Bool { blocks.contains { if case .rich = $0 { true } else { false } } }

    /// Reads a stored cell. Always ends up with at least one text block to type into.
    static func parse(_ html: String) -> CalendarNotesDocument {
        let body = CalendarNotes.stripToken(html)
        var blocks: [Block] = []
        for chunk in chunks(of: body) {
            switch classify(chunk) {
            case .line(let line):
                if case .text(let text, let original, _)? = blocks.last {
                    let joined = text + "\n" + line
                    blocks[blocks.count - 1] = .text(text: joined, original: original + chunk, originalText: joined)
                } else {
                    blocks.append(.text(text: line, original: chunk, originalText: line))
                }
            case .pill(let pill):
                blocks.append(.pill(pill, original: chunk))
            case .rich:
                blocks.append(.rich(chunk))
            }
        }
        if !blocks.contains(where: { if case .text = $0 { true } else { false } }) {
            blocks.append(.text(text: "", original: "", originalText: ""))
        }
        return CalendarNotesDocument(blocks: blocks, originalBody: body)
    }

    /// The body to store: untouched blocks as read, edited text as one paragraph per line.
    func body() -> String {
        blocks.map { block in
            switch block {
            case .text(let text, let original, let originalText):
                text == originalText ? original : Self.paragraphs(text)
            case .pill(let pill, let original):
                original.isEmpty ? "<p>\(CalendarNotes.pillHTML(id: pill.id, label: pill.label))</p>" : original
            case .rich(let html):
                html
            }
        }.joined()
    }

    // MARK: Editing

    func text(at index: Int) -> String {
        guard blocks.indices.contains(index), case .text(let text, _, _) = blocks[index] else { return "" }
        return text
    }

    mutating func setText(_ text: String, at index: Int) {
        guard blocks.indices.contains(index), case .text(_, let original, let originalText) = blocks[index] else { return }
        blocks[index] = .text(text: text, original: original, originalText: originalText)
    }

    /// Every pill in the cell, in order, whether on its own line or inside formatted text.
    var pills: [CalendarNotes.Pill] {
        var seen = Set<String>()
        return blocks.flatMap { block -> [CalendarNotes.Pill] in
            switch block {
            case .pill(let pill, _): [pill]
            case .rich(let html): CalendarNotes.pills(in: html)
            case .text: []
            }
        }.filter { seen.insert($0.id).inserted }
    }

    /// A new pill goes on its own line at the end, as the native editor has always added it.
    mutating func addPill(id: String, label: String) {
        guard !pills.contains(where: { $0.id == id }) else { return }
        blocks.append(.pill(.init(id: id, label: label), original: ""))
    }

    mutating func renamePill(id: String, label: String) {
        blocks = blocks.map { block in
            switch block {
            case .pill(let pill, _) where pill.id == id:
                .pill(.init(id: id, label: label), original: "")
            case .rich(let html):
                .rich(CalendarNotes.renamePill(in: html, id: id, label: label))
            default:
                block
            }
        }
    }

    mutating func removePill(id: String) {
        blocks = blocks.compactMap { block in
            switch block {
            case .pill(let pill, _) where pill.id == id:
                nil
            case .rich(let html):
                .rich(CalendarNotes.removePill(from: html, id: id))
            default:
                block
            }
        }
    }

    // MARK: Reading the HTML

    private enum Chunk { case line(String), pill(CalendarNotes.Pill), rich }

    private static let tagPattern = #/<(\/?)([A-Za-z][A-Za-z0-9]*)[^>]*?(\/?)>/#
    private static let emptyPattern = #/^\s*(<br\s*\/?>)?\s*$/#.ignoresCase()
    private static let pillOnlyPattern = #/^\s*<span class="package-pill"[^>]*>[^<]*<\/span>\s*$/#

    /// The body's top-level elements and loose text, in order; joined they give the body back
    /// exactly. Whitespace between elements rides with the element before it. Unbalanced HTML
    /// comes back as one chunk (shown read-only).
    static func chunks(of body: String) -> [String] {
        var chunks: [String] = []
        var depth = 0
        var blockStart = body.startIndex
        var cursor = body.startIndex
        for match in body.matches(of: tagPattern) {
            let range = match.range
            let name = match.output.2.lowercased()
            let isClose = !match.output.1.isEmpty
            let isVoid = !match.output.3.isEmpty || name == "br"
            if depth == 0, range.lowerBound > cursor {
                chunks.append(String(body[cursor..<range.lowerBound]))
                cursor = range.lowerBound
            }
            if isVoid {
                if depth == 0 { chunks.append(String(body[range])); cursor = range.upperBound }
            } else if isClose {
                depth -= 1
                guard depth >= 0 else { return body.isEmpty ? [] : [body] }
                if depth == 0 { chunks.append(String(body[blockStart..<range.upperBound])); cursor = range.upperBound }
            } else {
                if depth == 0 { blockStart = range.lowerBound }
                depth += 1
            }
        }
        guard depth == 0 else { return body.isEmpty ? [] : [body] }
        if cursor < body.endIndex { chunks.append(String(body[cursor...])) }
        var merged: [String] = []
        for chunk in chunks {
            if chunk.allSatisfy(\.isWhitespace), !merged.isEmpty {
                merged[merged.count - 1] += chunk
            } else if let first = merged.first, first.allSatisfy(\.isWhitespace) {
                merged[0] = first + chunk
            } else {
                merged.append(chunk)
            }
        }
        return merged.joined() == body ? merged : (body.isEmpty ? [] : [body])
    }

    private static func classify(_ chunk: String) -> Chunk {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<p>"), trimmed.hasSuffix("</p>"), trimmed.count >= 7 else { return .rich }
        let inner = String(trimmed.dropFirst(3).dropLast(4))
        if inner.wholeMatch(of: emptyPattern) != nil { return .line("") }
        if !inner.contains("<"), !inner.contains(">") {
            let line = DayContent.decodeEntities(inner).replacing(#/\s*\n\s*/#, with: " ")
            return .line(line)
        }
        if inner.wholeMatch(of: pillOnlyPattern) != nil, let pill = CalendarNotes.pills(in: inner).first {
            return .pill(pill)
        }
        return .rich
    }

    /// Edited text: one paragraph per line and an empty line as the Portal's `<p><br></p>`, so
    /// spacing typed on the phone stays; text with nothing in it writes nothing.
    static func paragraphs(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { !$0.isEmpty }) else { return "" }
        return lines.map { $0.isEmpty ? "<p><br></p>" : "<p>\(CalendarCellHTML.escape($0))</p>" }.joined()
    }
}
