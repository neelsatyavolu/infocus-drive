import Foundation
import Observation

/// People this person blocked in Messages, kept on this iPhone for the signed-in account.
/// Blocking hides someone's direct messages and their messages in group chats here (a
/// "Hidden: blocked" line can show one again). It doesn't tell them or change the Portal:
/// InFocus producers and the adviser moderate the class, and Report reaches them.
@MainActor @Observable
final class BlockList {
    struct Person: Codable, Hashable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    static let shared = BlockList()

    private(set) var people: [Person] = []
    private var account: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Loads the list for whoever signed in (nil after sign-out).
    func use(account: String?) {
        self.account = account?.lowercased()
        people = load()
    }

    func isBlocked(_ userId: String) -> Bool {
        people.contains { $0.id == userId }
    }

    func block(id: String, name: String) {
        guard !isBlocked(id) else { return }
        people.append(Person(id: id, name: name))
        save()
    }

    func unblock(_ userId: String) {
        people.removeAll { $0.id == userId }
        save()
    }

    private var key: String? {
        account.map { "blockedPeople.\($0)" }
    }

    private func load() -> [Person] {
        guard let key, let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Person].self, from: data)) ?? []
    }

    private func save() {
        guard let key else { return }
        defaults.set(try? JSONEncoder().encode(people), forKey: key)
    }
}
