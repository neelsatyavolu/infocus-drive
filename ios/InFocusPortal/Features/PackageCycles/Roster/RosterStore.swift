import Foundation
import Observation

/// One cycle's roster and the edits allowed on it. Every edit re-reads the cycle first and
/// changes only the touched group, because the Portal saves a cycle as a whole: this keeps
/// someone else's change to another group from being written over.
@MainActor @Observable
final class RosterStore {
    private(set) var state: Loadable<RosterPayload> = .idle
    private(set) var people: [RosterPerson] = []
    private(set) var saving = false
    var errorMessage: String?
    var notice: String?

    /// The cycle shown; nil until the first load picks the active one.
    private(set) var cycle: Int?
    private let service: PackageCyclesService

    init(service: PackageCyclesService, cycle: Int? = nil) {
        self.service = service
        self.cycle = cycle
    }

    var roster: RosterPayload? { state.value }
    var canEdit: Bool { roster?.canEdit ?? false }
    var peopleById: [String: RosterPerson] { Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }

    func row(_ id: String) -> RosterRow? { roster?.rows.first { $0.id == id } }

    func load(cycle requested: Int? = nil) async {
        if let requested { cycle = requested }
        if state.value == nil || requested != nil { state = .loading }
        do {
            let payload = try await service.roster(cycle: cycle)
            cycle = payload.activeCycleNumber
            state = .loaded(payload)
        } catch {
            if state.value == nil || requested != nil { state = .failed(Loadable<RosterPayload>.message(for: error)) }
            else { errorMessage = Loadable<RosterPayload>.message(for: error) }
        }
    }

    func loadPeople() async {
        guard people.isEmpty else { return }
        people = (try? await service.people()) ?? []
    }

    // MARK: Edits (chart editors only; the Portal refuses everyone else)

    @discardableResult
    func update(_ rowId: String, success: String? = nil,
                _ change: @escaping (inout [String: JSONValue]) -> Void) async -> Bool {
        await save(success: success) { rows in
            guard let index = rows.firstIndex(where: { $0["id"]?.string == rowId }) else {
                throw RosterEditError("This group was removed. Pull to refresh.")
            }
            change(&rows[index])
        }
    }

    func setTopic(_ rowId: String, _ topic: String) async -> Bool {
        await update(rowId, success: "Topic saved.") { $0["groupTopic"] = .string(String(topic.prefix(280))) }
    }

    func setNotes(_ rowId: String, interviews: String, ideas: String, notes: String) async -> Bool {
        await update(rowId, success: "Notes saved.") { row in
            row["possibleInterviews"] = .string(interviews)
            row["possibleIdeas"] = .string(ideas)
            row["notes"] = .string(String(notes.prefix(1200)))
        }
    }

    func setMembers(_ rowId: String, _ ids: [String]) async -> Bool {
        let people = peopleById
        return await update(rowId) { RosterLogic.setMembers(&$0, ids: Array(ids.prefix(20)), people: people) }
    }

    func assign(_ rowId: String, to userId: String?) async -> Bool {
        let executives = Set(roster?.executives.map(\.userId) ?? [])
        return await update(rowId, success: userId == nil ? "Unassigned." : "Producer assigned.") {
            RosterLogic.assign(&$0, to: userId, executiveIds: executives)
        }
    }

    /// Adds a blank group at the end; returns its id once saved.
    func addGroup() async -> String? {
        let before = Set(roster?.rows.map(\.id) ?? [])
        guard await save(success: "Group added.", { $0.append(RosterLogic.newRow()) }) else { return nil }
        return roster?.rows.last { !before.contains($0.id) }?.id
    }

    func delete(_ rowId: String) async -> Bool {
        await save(success: "Group deleted.") { rows in rows.removeAll { $0["id"]?.string == rowId } }
    }

    func move(_ rowId: String, to target: Int) async -> Bool {
        await perform(success: "Moved to Cycle \(target).") { [service] in try await service.move(rowId: rowId, to: target) }
    }

    // MARK: Saving

    private func save(success: String?, _ change: @escaping (inout [[String: JSONValue]]) throws -> Void) async -> Bool {
        await perform(success: success) { [service, cycle] in
            guard let cycle else { throw RosterEditError("Pick a cycle first.") }
            var rows = try await service.roster(cycle: cycle).rows.map(\.raw)
            try change(&rows)
            try await service.saveRoster(cycle: cycle, rows: rows)
        }
    }

    private func perform(success: String?, _ action: @escaping () async throws -> Void) async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        do {
            try await action()
            await load()
            notice = success
            return true
        } catch {
            errorMessage = Loadable<RosterPayload>.message(for: error)
            await load()
            return false
        }
    }
}

struct RosterEditError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
