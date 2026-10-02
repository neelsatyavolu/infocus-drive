#if DEBUG
import Foundation

/// Producer calls for `-InFocusStubSession` screenshots: edits live in memory and show up
/// in `CalendarStubData.month`, so a saved change stays after the reload. Fictional names only.
extension CalendarEditAPI {
    static let stub = CalendarEditAPI(
        saveCell: { date, content in CalendarStubEdits.shared.set(content, for: date); return content },
        setAnchors: { date, names, _ in CalendarStubEdits.shared.setSection(date, heading: "Anchors", names: names) },
        suggestAnchors: { _ in ["Kai", "Rio"] },
        setPa: { date, names in CalendarStubEdits.shared.setSection(date, heading: "PA Announcers", names: names) },
        suggestPa: { _ in ["Juno", "Abby"] },
        setShowManager: { date, name in
            CalendarStubEdits.shared.setManager(name, for: date)
            return ShowManagerResult(content: nil, name: name.isEmpty ? "Sage" : name, source: name.isEmpty ? "rotation" : "manual",
                                     pool: CalendarStubData.managerPool)
        },
        setCrew: { date, role, names in CalendarStubEdits.shared.setSection(date, heading: role, names: names, joiner: ", ") },
        wipeAnchors: { _ in [] },
        castCounts: {
            CalendarStubData.members.enumerated().map { index, name in CastCount(name: name, anchors: index % 3, pa: index % 2) }
        },
        syncDoc: { _ in 18 },
        showOverview: { date in CalendarStubData.overview(date) }
    )
}

/// The stub's saved cells and show managers (thread-safe; tests and screenshots only).
final class CalendarStubEdits: @unchecked Sendable {
    static let shared = CalendarStubEdits()
    private let lock = NSLock()
    private var cells: [String: String] = [:]
    private var managers: [String: String] = [:]

    func content(for date: String) -> String? { lock.withLock { cells[date] } }
    func manager(for date: String) -> String? { lock.withLock { managers[date] } }
    func set(_ content: String, for date: String) { lock.withLock { cells[date] = content } }
    func setManager(_ name: String, for date: String) { lock.withLock { managers[date] = name.isEmpty ? nil : name } }

    /// Rewrites one "Heading:" section of the stub cell, like the Portal's setters.
    func setSection(_ date: String, heading: String, names: [String], joiner: String = " & ") -> String {
        let current = content(for: date) ?? CalendarStubData.cell(for: date)
        let line = names.joined(separator: joiner)
        let inner = line.isEmpty ? "<p><br></p>" : "<p>\(CalendarCellHTML.escape(line))</p>"
        let next = CalendarCellHTML.replaceSection(current, heading: heading, nextHeadings: CalendarStubData.headings, inner: inner)
        set(next, for: date)
        return next
    }
}
#endif
