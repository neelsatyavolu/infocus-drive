import Foundation
import Observation

/// Submitted announcements for one visit to the screen: load, refresh, delete, invite.
@MainActor @Observable
final class SubmittedModel {
    private(set) var state: Loadable<SubmittedBoard> = .idle
    private(set) var deletingID: String?
    var actionError: String?
    /// Sections the person opened or closed (others follow the Portal's default).
    var expanded: [String: Bool] = [:]

    func load(api: AnnouncementsAPI, force: Bool = false) async {
        if !force, state.value != nil || state.isLoading { return }
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.submitted())
        } catch {
            if state.value == nil { state = .failed(Loadable<SubmittedBoard>.message(for: error)) }
            else { actionError = Loadable<Bool>.message(for: error) }
        }
    }

    func isOpen(_ bucket: SubmittedBoard.Bucket) -> Bool { expanded[bucket.id] ?? bucket.defaultOpen }

    func toggle(_ bucket: SubmittedBoard.Bucket) { expanded[bucket.id] = !isOpen(bucket) }

    /// Returns true when the Portal removed it; the list drops it right away.
    func delete(_ entry: SubmittedEntry, api: AnnouncementsAPI) async -> Bool {
        guard deletingID == nil else { return false }
        deletingID = entry.id
        defer { deletingID = nil }
        do {
            try await api.deleteSubmitted(entry.id)
            if let board = state.value { state = .loaded(Self.removing(entry.id, from: board)) }
            return true
        } catch {
            actionError = Loadable<Bool>.message(for: error)
            return false
        }
    }

    /// The board without one entry; a section left empty disappears, as on the web.
    nonisolated static func removing(_ id: String, from board: SubmittedBoard) -> SubmittedBoard {
        var next = board
        next.buckets = board.buckets.compactMap { bucket in
            var bucket = bucket
            bucket.entries.removeAll { $0.id == id }
            return bucket.entries.isEmpty ? nil : bucket
        }
        next.total = next.buckets.reduce(0) { $0 + $1.entries.count }
        return next
    }
}

/// How dates read on a submitted card (pure, so it's unit tested).
enum SubmittedDates {
    /// "2026-10-03" → "Sat, Oct 3"; anything else (old sheet rows) as written; blank → "Not set".
    static func day(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Not set" }
        guard let date = dateKey.date(from: trimmed) else { return trimmed }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func range(_ entry: SubmittedEntry) -> String {
        entry.isPermanent ? "Permanent" : "\(day(entry.startDate)) – \(day(entry.endDate))"
    }

    /// The submission time ("Sep 28, 2026, 10:30 AM"), or the raw value.
    static func submitted(_ value: String) -> String {
        if let date = iso.date(from: value) ?? isoWhole.date(from: value) {
            return date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
        }
        return value.isEmpty ? "Unknown time" : value
    }

    /// An http(s) link, or nil when the field holds plain words.
    static func link(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        return URL(string: trimmed)
    }

    private static let dateKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoWhole = ISO8601DateFormatter()
}
