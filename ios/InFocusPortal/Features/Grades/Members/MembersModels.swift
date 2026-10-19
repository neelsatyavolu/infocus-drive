import Foundation

/// `GET api/members` (producers): every class member with their producer notes, General (cycle 0)
/// and one per package cycle (`src/server/member-notes.ts`).
struct MembersPayload: Decodable, Hashable, Sendable {
    struct Cycle: Decodable, Hashable, Sendable, Identifiable {
        let cycleNumber: Int
        let focus: String

        var id: Int { cycleNumber }
    }

    struct Member: Decodable, Hashable, Sendable, Identifiable {
        let id: String
        let name: String?
        let email: String?
        /// Note text by cycle number as a string ("0" is General).
        let notesByCycle: [String: String]
    }

    let cycles: [Cycle]
    let members: [Member]
}

/// `PATCH api/members/notes`.
struct MemberNoteSave: Codable, Equatable, Sendable {
    let userId: String
    let cycleNumber: Int
    let notes: String
}

/// Which members the list shows for the chosen tab.
enum MemberNoteFilter: String, CaseIterable, Identifiable {
    case all, with, without

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .with: "With notes"
        case .without: "No notes"
        }
    }
}

/// A note's save state, shown beside its editor (never by color alone).
enum MemberNoteState: Equatable {
    case idle, dirty, saving, saved, failed(String)

    var label: String? {
        switch self {
        case .idle: nil
        case .dirty: "Unsaved"
        case .saving: "Saving"
        case .saved: "Saved"
        case .failed: "Not saved"
        }
    }
}

/// The web Members page's rules (`app/(app)/members/member-notes-model.ts`), without UI.
enum MembersLogic {
    static let generalCycle = 0
    static let noteMax = 4000

    /// "userId:cycle" (`memberNoteKey`).
    static func key(_ userId: String, _ cycle: Int) -> String { "\(userId):\(cycle)" }

    /// Splits at the last colon (user ids never end in ":<digits>").
    static func parseKey(_ key: String) -> (userId: String, cycle: Int)? {
        guard let colon = key.lastIndex(of: ":"), colon > key.startIndex,
              let cycle = Int(key[key.index(after: colon)...]) else { return nil }
        return (String(key[..<colon]), cycle)
    }

    static func notes(from members: [MembersPayload.Member]) -> [String: String] {
        var notes: [String: String] = [:]
        for member in members {
            for (cycle, text) in member.notesByCycle {
                if let number = Int(cycle) { notes[key(member.id, number)] = text }
            }
        }
        return notes
    }

    static func label(_ member: MembersPayload.Member) -> String {
        let name = member.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (member.email ?? "Unnamed member") : name
    }

    static func cycleCode(_ cycle: Int) -> String { cycle < 10 ? "0\(cycle)" : "\(cycle)" }

    /// "General" or "Cycle 03".
    static func tabTitle(_ cycle: Int) -> String { cycle == generalCycle ? "General" : "Cycle \(cycleCode(cycle))" }

    /// The tabs (General, then each cycle) on which this member has a note.
    static func tabsWithNotes(_ notes: [String: String], memberId: String, tabs: [Int]) -> [Int] {
        tabs.filter { !(notes[key(memberId, $0)] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// "No notes yet" or "Notes: General, Cycle 02".
    static func coverage(_ tabs: [Int]) -> String {
        tabs.isEmpty ? "No notes yet" : "Notes: " + tabs.map(tabTitle).joined(separator: ", ")
    }

    /// Search by name or email, then the note filter for the chosen tab.
    static func visible(_ members: [MembersPayload.Member], notes: [String: String], tab: Int,
                        filter: MemberNoteFilter, search: String) -> [MembersPayload.Member] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return members.filter { member in
            if !query.isEmpty {
                let haystack = "\(member.name ?? "") \(member.email ?? "")".lowercased()
                if !haystack.contains(query) { return false }
            }
            let hasNote = !(notes[key(member.id, tab)] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            switch filter {
            case .all: return true
            case .with: return hasNote
            case .without: return !hasNote
            }
        }
    }

    /// The header line for the chosen tab (copy from the web page).
    static func tabDescription(_ tab: Int, cycles: [MembersPayload.Cycle]) -> String {
        if tab == generalCycle {
            return "Standing notes on each reporter. Switch cycles for notes that stay with that package."
        }
        if let focus = cycles.first(where: { $0.cycleNumber == tab })?.focus.trimmingCharacters(in: .whitespaces),
           !focus.isEmpty {
            return "Cycle \(tab) · \(focus)"
        }
        return "Notes for package cycle \(tab)."
    }
}
