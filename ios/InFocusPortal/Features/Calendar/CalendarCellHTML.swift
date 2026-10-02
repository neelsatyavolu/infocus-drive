import Foundation

/// Writing a Master Calendar cell, the way the Portal's calendar-show-content.ts does:
/// a section is `<p><strong>Heading:</strong></p>` followed by its paragraphs, up to the
/// next known heading. Only the section being edited changes; everything else (anchors,
/// package pills, crew lists) is kept byte for byte.
enum CalendarCellHTML {
    static let showTemplate = "<p><strong>Anchors:</strong></p><p><br></p><p><strong>Package:</strong></p><p><br></p><p><br></p>"
        + "<p><strong>Show Director:</strong></p><p><br></p><p><strong>Show Manager:</strong></p><p><br></p>"

    /// Headings that can follow Show Director in a show cell.
    static let afterShowDirector = ["Show Manager", "Filmers", "Brunch Filmers", "Lunch Filmers", "Night Rally Filmers", "Editors"]

    /// "Abby & Otto" as one paragraph (the Portal's `nameParagraphs`), or an empty line.
    static func nameParagraph(_ names: [String]) -> String {
        let line = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(2).joined(separator: " & ")
        return line.isEmpty ? "<p><br></p>" : "<p>\(escape(line))</p>"
    }

    /// The Portal's `replaceCalendarSection`: swap a section's paragraphs, or add the
    /// section in front when the cell doesn't have it yet.
    static func replaceSection(_ html: String, heading: String, nextHeadings: [String], inner: String, fallback: String = "") -> String {
        let source = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : html
        guard let start = headingRange(heading, in: source) else {
            let block = "<p><strong>\(heading):</strong></p>\(inner)"
            return source.isEmpty ? block : block + source
        }
        let rest = String(source[start.upperBound...])
        let end = nextHeadings.compactMap { headingRange($0, in: rest)?.lowerBound }.min() ?? rest.endIndex
        return String(source[..<start.upperBound]) + inner + String(rest[end...])
    }

    static func setShowDirector(_ html: String, names: [String]) -> String {
        replaceSection(html, heading: "Show Director", nextHeadings: afterShowDirector,
                       inner: nameParagraph(names), fallback: showTemplate)
    }

    /// A class day's or a holiday's free text: one paragraph per line.
    static func notes(_ lines: [String]) -> String {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { "<p>\(escape($0))</p>" }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// `<p><strong>Heading:</strong></p>`, ignoring case and spaces, as the Portal matches it.
    private static func headingRange(_ heading: String, in html: String) -> Range<String.Index>? {
        let label = NSRegularExpression.escapedPattern(for: heading)
        return html.range(of: #"<p>\s*<strong>\s*"# + label + #":\s*</strong>\s*</p>"#,
                          options: [.regularExpression, .caseInsensitive])
    }
}

/// Who a producer may pick for each job, matching the Portal's pickers.
enum CastEligibility {
    enum Block: Equatable {
        case otherSlot
        case anchoredThisMonth
        case alreadyListed

        var reason: String {
            switch self {
            case .otherSlot: "In the other slot"
            case .anchoredThisMonth: "Anchors another show this month"
            case .alreadyListed: "Already on this list"
            }
        }
    }

    /// The pool, with a current value that's no longer in it kept at the top (the Portal's `optionsForValue`).
    static func options(_ pool: [String], keeping value: String) -> [String] {
        value.isEmpty || pool.contains(value) ? pool : [value] + pool
    }

    /// Nobody anchors twice in a month: names on the month's other show days.
    static func monthAnchors(in days: [CalendarDay], excluding date: String) -> Set<String> {
        let month = CalendarDates.monthKey(of: date)
        return Set(days.filter { $0.kind == .show && $0.date != date && CalendarDates.monthKey(of: $0.date) == month }
            .flatMap { $0.names(for: "Anchors") }
            .map { $0.lowercased() })
    }

    static func anchorBlock(_ name: String, otherSlot: String, monthAnchors: Set<String>) -> Block? {
        if !otherSlot.isEmpty, name.caseInsensitiveCompare(otherSlot) == .orderedSame { return .otherSlot }
        if monthAnchors.contains(name.lowercased()) { return .anchoredThisMonth }
        return nil
    }

    static func pairBlock(_ name: String, otherSlot: String) -> Block? {
        !otherSlot.isEmpty && name.caseInsensitiveCompare(otherSlot) == .orderedSame ? .otherSlot : nil
    }

    static func listBlock(_ name: String, listed: [String]) -> Block? {
        listed.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? .alreadyListed : nil
    }

    /// The two slots after one changes (an empty slot stays empty; the Portal keeps pick order).
    static func pair(_ current: [String], setting slot: Int, to name: String) -> [String] {
        var names = [current.first ?? "", current.count > 1 ? current[1] : ""]
        names[slot] = name
        return names.filter { !$0.isEmpty }
    }
}
