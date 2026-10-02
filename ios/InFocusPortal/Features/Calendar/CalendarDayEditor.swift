import Foundation
import Observation

/// Runs a producer's edits to one day: each save goes to the Portal, the stored cell shows
/// at once, then the month reloads so the calendar matches what the Portal kept.
/// Errors stay on screen in the Portal's own words.
@MainActor @Observable
final class CalendarDayEditor {
    let date: String
    private(set) var busy = false
    var error: String?

    private let edit: CalendarEditAPI
    private let read: CalendarAPI
    private let store: CalendarStore

    init(date: String, edit: CalendarEditAPI, read: CalendarAPI, store: CalendarStore? = nil) {
        self.date = date
        self.edit = edit
        self.read = read
        self.store = store ?? .shared
    }

    private var monthKey: String { CalendarDates.monthKey(of: date) }

    func setAnchors(_ names: [String]) async { await saveCell { try await self.edit.setAnchors(self.date, names, "manual") } }

    func randomizeAnchors() async {
        await saveCell {
            let suggested = try await self.edit.suggestAnchors(self.date)
            guard !suggested.isEmpty else { throw EditError("No eligible anchors left this month.") }
            return try await self.edit.setAnchors(self.date, suggested, "random")
        }
    }

    func setPa(_ names: [String]) async { await saveCell { try await self.edit.setPa(self.date, names) } }

    func randomizePa() async {
        await saveCell {
            let suggested = try await self.edit.suggestPa(self.date)
            guard !suggested.isEmpty else { throw EditError("No eligible PA announcers left this month.") }
            return try await self.edit.setPa(self.date, suggested)
        }
    }

    func setCrew(_ role: String, names: [String]) async { await saveCell { try await self.edit.setCrew(self.date, role, names) } }

    /// "" puts the day back on the rotation.
    func setShowManager(_ name: String) async {
        await run {
            let result = try await self.edit.setShowManager(self.date, name)
            self.store.apply(manager: result, for: self.date)
        }
    }

    func setShowDirector(_ names: [String]) async {
        await saveCell {
            let html = CalendarCellHTML.setShowDirector(try await self.freshContent(), names: names)
            return try await self.edit.saveCell(self.date, html)
        }
    }

    /// A class day's or a holiday's free text (show and PA cells keep their structure).
    func setNotes(_ text: String) async {
        await saveCell { try await self.edit.saveCell(self.date, CalendarCellHTML.notes(text.components(separatedBy: .newlines))) }
    }

    // MARK: -

    /// The cell as the Portal has it now, so a section edit never undoes someone else's change.
    private func freshContent() async throws -> String {
        let month = try await read.month(monthKey)
        return month.content(of: date)
    }

    private func saveCell(_ operation: @escaping () async throws -> String) async {
        await run { self.store.apply(content: try await operation(), for: self.date) }
    }

    private func run(_ operation: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await operation()
        } catch {
            self.error = Self.message(for: error)
        }
        await store.load(monthKey, api: read, force: true)
    }

    nonisolated static func message(for error: Error) -> String {
        (error as? EditError)?.message ?? Loadable<Bool>.message(for: error)
    }
}

/// A plain sentence for the person (the Portal's own errors arrive as `PortalError`).
struct EditError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
