import Foundation

/// A Master Calendar cell's HTML (`<p><strong>Anchors:</strong></p><p>Abby &amp; Otto</p>…`)
/// read as "Heading: lines" sections, the way the Portal's calendar-show-content.ts reads it.
/// Any heading is kept, so new crew lists show up without an app update.
enum DayContent {
    struct Section: Sendable, Equatable {
        let heading: String
        let lines: [String]
        /// People headings (anchors, managers, crews) split into names; others keep their lines.
        let isPeople: Bool

        var names: [String] { isPeople ? DayContent.splitNames(lines) : [] }
    }

    struct Parsed: Sendable, Equatable {
        let sections: [Section]
        let notes: [String]
    }

    /// Short forms the class types, mapped to the calendar's own headings.
    private static let aliases = ["sd": "Show Director", "sm": "Show Manager", "pa": "PA Announcers"]
    private static let peopleHeadings: Set<String> = [
        "anchors", "show director", "show manager", "pa announcers", "filmers",
        "brunch filmers", "lunch filmers", "night rally filmers", "editors"
    ]
    private static let headingPattern = #/^([A-Za-z][A-Za-z &'\/-]{0,30}?)\s*:\s*(.*)$/#

    static func parse(_ html: String) -> Parsed {
        var sections: [(heading: String, lines: [String])] = []
        var notes: [String] = []
        for line in lines(of: html) {
            if let match = line.wholeMatch(of: headingPattern), isHeading(String(match.1), rest: String(match.2)) {
                let raw = String(match.1).trimmingCharacters(in: .whitespaces)
                let heading = aliases[raw.lowercased()] ?? raw
                let rest = String(match.2).trimmingCharacters(in: .whitespaces)
                sections.append((heading, rest.isEmpty ? [] : [rest]))
            } else if sections.isEmpty {
                notes.append(line)
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        return Parsed(
            sections: sections.map { Section(heading: $0.heading, lines: $0.lines,
                                             isPeople: peopleHeadings.contains($0.heading.lowercased())) },
            notes: notes
        )
    }

    /// "Abby & Otto", "Sage, Abby", "Otto and Sage" → names, no duplicates.
    static func splitNames(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines
            .flatMap { $0.split(separator: #/\s*(?:,|\/|&|\+|\band\b)\s*/#) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// A heading is a known label, or any short "Label:" line with nothing after it.
    private static func isHeading(_ label: String, rest: String) -> Bool {
        let key = label.trimmingCharacters(in: .whitespaces).lowercased()
        if peopleHeadings.contains(key) || aliases[key] != nil || key == "package" || key == "packages" { return true }
        return rest.isEmpty && label.split(separator: " ").count <= 4
    }

    /// Paragraphs and line breaks become lines; tags go, entities are decoded, blanks dropped.
    static func lines(of html: String) -> [String] {
        let text = html
            .replacing(#/<br\s*\/?>/#.ignoresCase(), with: "\n")
            .replacing(#/<\/(p|div|li)>/#.ignoresCase(), with: "\n")
            .replacing(#/<[^>]+>/#, with: "")
        return decodeEntities(text)
            .split(separator: "\n")
            .map { $0.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
