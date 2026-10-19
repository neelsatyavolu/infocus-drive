import Foundation

/// `GET api/teleprompter[?showDate=]`: the workspace's show scripts. Opening it also creates
/// the next show's script and fills in its anchors and package tosses on the Portal.
struct TeleprompterPayload: Decodable, Sendable, Equatable {
    struct Autofill: Decodable, Sendable, Equatable {
        /// "ok", "warning" or "unavailable".
        let status: String
        let message: String?
    }

    let workspaceId: String
    let canEdit: Bool
    let nextShowDateIso: String
    var docs: [TeleprompterDoc]
    let autofill: Autofill
}

/// One show script.
struct TeleprompterDoc: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    var title: String
    let orderIndex: Int
    /// An ISO instant (noon UTC on the show day), or nil for a script that isn't a show's.
    var showDate: String? = nil
    let createdAt: Date
    let updatedAt: Date
    var sections: [TeleprompterSection]
}

/// One section ("A1", "A2"…) of a script.
struct TeleprompterSection: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    var label: String
    var content: String
    let orderIndex: Int
    let createdAt: Date
    let updatedAt: Date
}

/// `PATCH api/teleprompter/docs/<id>`: the renamed script (no sections).
struct TeleprompterDocTitle: Decodable, Sendable, Equatable {
    let id: String
    let title: String
}

/// The Portal's teleprompter rules (app/(app)/teleprompter/teleprompter-model.ts and
/// src/lib/teleprompter-run-script.ts).
enum TeleprompterScript {
    static let titleMax = 140
    static let labelMax = 32
    static let contentMax = 40_000

    /// "2026-10-21" from a show date ISO string.
    static func showDateKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let key = String(value.prefix(10))
        return key.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil ? key : nil
    }

    /// Newest show first (scripts without a show date by when they were made).
    static func sorted(_ docs: [TeleprompterDoc]) -> [TeleprompterDoc] {
        func stamp(_ doc: TeleprompterDoc) -> TimeInterval {
            (doc.showDate.flatMap(PortalJSON.date(from:)) ?? doc.createdAt).timeIntervalSince1970
        }
        return docs.sorted { left, right in
            if stamp(left) != stamp(right) { return stamp(left) > stamp(right) }
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.orderIndex > right.orderIndex
        }
    }

    /// The script to open: the one asked for, else the show's, else the next show's, else the newest.
    static func initial(_ docs: [TeleprompterDoc], docId: String?, showDate: String?, nextShowIso: String) -> TeleprompterDoc? {
        if let docId, let doc = docs.first(where: { $0.id == docId }) { return doc }
        if let showDate, let doc = docs.first(where: { showDateKey($0.showDate) == showDate }) { return doc }
        if let next = showDateKey(nextShowIso), let doc = docs.first(where: { showDateKey($0.showDate) == next }) { return doc }
        return sorted(docs).first
    }

    // MARK: Sections

    private static let beatHeading = #/(OPEN(ING)?|PACKAGE|BULLETIN|CLOS(E|ING)|INTRO|OUTRO)/#.ignoresCase()
    private static let placeholder = #/\[INSERT[^\]]*\]/#.ignoresCase()

    /// The Portal's `getSectionDisplayParts`: a beat heading on the first line ("OPEN") becomes
    /// part of the badge ("A1 - Open") and leaves the text.
    static func displayParts(label: String, content: String) -> (badge: String, beat: String?, content: String) {
        let lines = content.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return (label, nil, content)
        }
        let heading = lines[index].trimmingCharacters(in: .whitespaces)
        guard heading.wholeMatch(of: beatHeading) != nil else { return (label, nil, content) }
        let beat = heading.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        var rest = lines
        rest.remove(at: index)
        let body = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ("\(label) - \(beat)", beat, body)
    }

    static func hasPlaceholder(_ content: String) -> Bool { content.firstMatch(of: placeholder) != nil }

    /// "To fill" (an [INSERT …] is left), "Empty", or nil.
    static func status(of section: TeleprompterSection) -> String? {
        if displayParts(label: section.label, content: section.content).content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Empty"
        }
        return hasPlaceholder(section.content) ? "To fill" : nil
    }

    static func toFillCount(_ doc: TeleprompterDoc) -> Int {
        doc.sections.filter { hasPlaceholder($0.content) }.count
    }

    /// The one status a script row shows: Today > Next show > To fill · n > No sections.
    static func docStatus(_ doc: TeleprompterDoc, today: String, nextShow: String?) -> (label: String, warning: Bool)? {
        let key = showDateKey(doc.showDate)
        if let key, key == today { return ("Today", false) }
        if let key, key == nextShow { return ("Next show", false) }
        let toFill = toFillCount(doc)
        if toFill > 0 { return ("To fill · \(toFill)", true) }
        if doc.sections.isEmpty { return ("No sections", false) }
        return nil
    }

    /// Text split into plain runs and [INSERT …] placeholders (highlighted, display only).
    static func placeholderRuns(_ text: String) -> [(text: String, placeholder: Bool)] {
        var runs: [(String, Bool)] = []
        var rest = text[...]
        while let match = rest.firstMatch(of: placeholder) {
            if match.range.lowerBound > rest.startIndex { runs.append((String(rest[..<match.range.lowerBound]), false)) }
            runs.append((String(rest[match.range]), true))
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { runs.append((String(rest), false)) }
        return runs
    }
}

/// How run mode shows each line (the Portal's `classifyRunScriptLine`).
enum RunScriptLine: Equatable {
    case gap
    case camera(String)
    case cue(String, spoken: String?)
    case spoken(String)

    private static let camera = #/CAM\s*\d+/#.ignoresCase()
    private static let braceCue = #/\{[^}]+\}/#
    private static let bracketCue = #/\[[A-Z][A-Z0-9 \-]*\]/#.ignoresCase()
    private static let rolePrefix =
        #/(ANCHOR|CO[\s-]?ANCHOR|CAM\s*\d+|TALENT|HOST|NARRATOR|REPORTER|VOICE\s*OVER|VO|SOT)\s*[:\-]\s*(.*)/#.ignoresCase()
    private static let standaloneCue =
        #/(ANCHOR|CO[\s-]?ANCHOR|HOLD|ROLL\s+(INTRO|PACKAGE|OUTRO)|OPEN|BULLETIN|PACKAGE|CLOSING|TALENT|HOST|NARRATOR|REPORTER|VOICE\s*OVER|VO|SOT)/#.ignoresCase()

    static func classify(_ line: String) -> RunScriptLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .gap }
        if trimmed.wholeMatch(of: camera) != nil { return .camera(collapse(trimmed).uppercased()) }
        if let match = trimmed.wholeMatch(of: rolePrefix) {
            let role = String(match.output.1)
            if role.wholeMatch(of: camera) != nil { return .camera(cueLabel(role)) }
            let spoken = String(match.output.2).trimmingCharacters(in: .whitespaces)
            return .cue(cueLabel(role), spoken: spoken.isEmpty ? nil : spoken)
        }
        if trimmed.wholeMatch(of: braceCue) != nil || trimmed.wholeMatch(of: bracketCue) != nil
            || trimmed.wholeMatch(of: standaloneCue) != nil {
            return .cue(cueLabel(trimmed), spoken: nil)
        }
        return .spoken(trimmed)
    }

    /// The Portal's `formatRunCueLabel`: "{co anchor}" → "COANCHOR".
    static func cueLabel(_ value: String) -> String {
        var label = value.trimmingCharacters(in: .whitespaces)
        if label.hasPrefix("{"), label.hasSuffix("}"), label.count > 2 {
            let inner = label.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { label = inner }
        }
        if label.hasPrefix("["), label.hasSuffix("]"), label.count > 2 {
            let inner = label.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { label = inner }
        }
        let normalized = collapse(label).uppercased()
        return normalized == "CO ANCHOR" || normalized == "CO-ANCHOR" ? "COANCHOR" : normalized
    }

    private static func collapse(_ text: String) -> String { text.replacing(#/\s+/#, with: " ") }

    enum Tone: Equatable { case plain, red, yellow }

    /// `[RED]…[/RED]` and `[YELLOW]…[/YELLOW]` runs inside a spoken line.
    static func segments(_ text: String) -> [(text: String, tone: Tone)] {
        let styled = #/\[(RED|YELLOW)\](.*?)\[\/(RED|YELLOW)\]/#.ignoresCase()
        var result: [(String, Tone)] = []
        var rest = text[...]
        while let match = rest.firstMatch(of: styled) {
            if match.range.lowerBound > rest.startIndex { result.append((String(rest[..<match.range.lowerBound]), .plain)) }
            let open = match.output.1.uppercased()
            let close = match.output.3.uppercased()
            if open == close {
                result.append((String(match.output.2), open == "RED" ? .red : .yellow))
            } else {
                result.append((String(rest[match.range]), .plain))
            }
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { result.append((String(rest), .plain)) }
        return result
    }
}

/// Run mode's scrolling (src/lib/teleprompter-motion.ts): signed points per second, positive forward.
struct TeleprompterPlayback: Equatable {
    static let step: Double = 36
    static let maxSpeed: Double = 640
    static let startSpeed: Double = 72

    enum Control { case faster, slower, back, forward, toggle }

    var paused = false
    var speed = startSpeed

    /// The Portal's `teleprompterArrowState`: Space keeps the speed; arrows after a pause restart from 0.
    func applying(_ control: Control) -> TeleprompterPlayback {
        if control == .toggle { return TeleprompterPlayback(paused: !paused, speed: speed) }
        let current = paused ? 0 : speed
        switch control {
        case .faster, .slower:
            let delta = control == .faster ? Self.step : -Self.step
            return TeleprompterPlayback(paused: false, speed: max(-Self.maxSpeed, min(Self.maxSpeed, current + delta)))
        case .back:
            return TeleprompterPlayback(paused: false, speed: current == 0 ? 0 : -abs(current))
        default:
            return TeleprompterPlayback(paused: false, speed: abs(current))
        }
    }

    /// "REV 36" so direction never relies on a minus sign.
    var label: String { speed < 0 ? "REV \(Int(abs(speed)))" : "\(Int(speed))" }

    /// The next scroll position after `seconds`, kept between the top and the end of the script.
    func advance(_ position: Double, seconds: Double, maxPosition: Double) -> Double {
        guard !paused else { return position }
        return min(max(0, position + speed * seconds), max(0, maxPosition))
    }
}
