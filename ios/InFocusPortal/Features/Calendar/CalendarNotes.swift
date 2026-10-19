import Foundation

/// Helpers for a class day's or a holiday's cell, matching the Portal's Master Calendar: package
/// pills (`<span class="package-pill" data-package-id=…>`, which mark the package aired) and, on a
/// class day, the token that hides the day's scenic image (src/lib/master-calendar-cells.ts).
/// `CalendarNotesDocument` edits the notes themselves.
enum CalendarNotes {
    struct Pill: Equatable, Sendable, Identifiable {
        let id: String
        var label: String
    }

    /// The Portal's hide-image token (kept for existing Monday rows).
    static let hideImageToken = "[[NO_MONDAY_IMAGE]]"

    private static let pillPattern = #/<span class="package-pill"[^>]*>[^<]*</span>/#
    private static let idPattern = #/data-package-id="([^"]+)"/#
    private static let labelPattern = #/data-display-label="([^"]*)"/#

    /// The pills in some HTML, in order, without repeats (an older pill without a display label
    /// keeps its text).
    static func pills(in html: String) -> [Pill] {
        var pills: [Pill] = []
        for match in html.matches(of: pillPattern) {
            let span = String(match.output)
            guard let id = span.firstMatch(of: idPattern).map({ String($0.output.1) }),
                  !pills.contains(where: { $0.id == id }) else { continue }
            let attribute = span.firstMatch(of: labelPattern).map { String($0.output.1) }
            let inner = span.replacing(#/<[^>]+>/#, with: "")
            pills.append(Pill(id: id, label: DayContent.decodeEntities(attribute ?? inner)))
        }
        return pills
    }

    /// The Portal's `renamePillInHtml`: the label attribute and text change; the package stays.
    static func renamePill(in html: String, id: String, label: String) -> String {
        let pattern = #"(<span class="package-pill"[^>]*data-package-id=""# + NSRegularExpression.escapedPattern(for: id)
            + #""[^>]*data-display-label=")[^"]*("[^>]*>)[^<]*(</span>)"#
        guard let regex = try? Regex(pattern) else { return html }
        let safe = CalendarCellHTML.escape(label)
        return html.replacing(regex) { match in
            let open = match.output[1].substring ?? ""
            let middle = match.output[2].substring ?? ""
            let close = match.output[3].substring ?? ""
            return "\(open)\(safe)\(middle)\(safe)\(close)"
        }
    }

    /// The Portal's `removePillFromHtml`.
    static func removePill(from html: String, id: String) -> String {
        let pattern = #"<span class="package-pill"[^>]*data-package-id=""# + NSRegularExpression.escapedPattern(for: id)
            + #""[^>]*>[^<]*</span>"#
        guard let regex = try? Regex(pattern) else { return html }
        return html.replacing(regex, with: "")
    }

    /// The Portal's `hasImageHidden`.
    static func isImageHidden(_ html: String) -> Bool { html.contains(hideImageToken) }

    /// The Portal's `withImageHidden`: the token in front of the cell, nothing else changed.
    static func withImageHidden(_ html: String) -> String {
        let clean = stripToken(html)
        return clean.isEmpty ? hideImageToken : hideImageToken + clean
    }

    /// The Portal's `buildPillHtml`.
    static func pillHTML(id: String, label: String) -> String {
        let safe = CalendarCellHTML.escape(label)
        return "<span class=\"package-pill\" data-package-id=\"\(CalendarCellHTML.escape(id))\" data-display-label=\"\(safe)\">\(safe)</span>"
    }

    /// The Portal's `extractPackageIds`: every pill in a cell, wherever it sits.
    static func packageIds(in html: String) -> Set<String> {
        Set(html.matches(of: idPattern).map { String($0.output.1) })
    }

    static func stripToken(_ html: String) -> String {
        html.replacingOccurrences(of: hideImageToken, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to mark aired and what to put back after a save (the Portal's `syncAiredStateForPills`).
    static func airedChanges(before: String, after: String) -> (added: [String], removed: [String]) {
        let old = packageIds(in: before)
        let new = packageIds(in: after)
        return (new.subtracting(old).sorted(), old.subtracting(new).sorted())
    }

    /// The scenic photo the Portal shows on a class day (`scenicImageForDate`: a 32-bit string hash).
    static func scenicImage(for date: String) -> URL? {
        var hash: Int32 = 0
        for unit in date.utf16 {
            hash = (hash &<< 5) &- hash &+ Int32(unit)
        }
        let index = Int(hash.magnitude) % scenicImages.count
        return URL(string: scenicImages[index])
    }

    /// The Portal's royalty-free scenic images (src/lib/master-calendar-cells.ts).
    static let scenicImages = [
        "https://images.unsplash.com/photo-1439853949127-fa647821eba0?auto=format&fit=crop&w=800&q=75",
        "https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=800&q=75",
        "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=800&q=75",
        "https://images.unsplash.com/photo-1447752875215-b2761acb3c5d?auto=format&fit=crop&w=800&q=75",
        "https://images.unsplash.com/photo-1431794062232-2a99a5431c6c?auto=format&fit=crop&w=800&q=75",
        "https://images.unsplash.com/photo-1501785888041-af3ef285b470?auto=format&fit=crop&w=800&q=75",
    ]
}

/// `GET api/master-calendar/packages?q=` (producers): Portal media to add as a pill.
struct CalendarPackageOption: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let projectName: String
    let approvalStatus: String?
    let airedAt: Date?

    var statusLabel: String? {
        switch approvalStatus {
        case "IN_REVIEW": "In review"
        case "NEEDS_CHANGES": "Needs changes"
        case "APPROVED": "Approved"
        case "AIRED": "Aired"
        default: nil
        }
    }
}
