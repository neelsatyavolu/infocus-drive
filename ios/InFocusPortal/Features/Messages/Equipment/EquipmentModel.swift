import Foundation
import Observation

/// Equipment for one person: their gear, the request flow, and the manager queues.
@MainActor @Observable
final class EquipmentModel {
    private(set) var canManage = false
    private(set) var mine: Loadable<MyEquipment> = .idle
    private(set) var available: Loadable<[GearItem]> = .idle
    private(set) var requests: Loadable<[ManagedRequests.Request]> = .idle
    private(set) var out: Loadable<[ManagedOut.Item]> = .idle
    private(set) var inventory: Loadable<[ManagedOut.Item]> = .idle
    private(set) var managers: Loadable<[ManagerRow]> = .idle
    private(set) var members: Loadable<[PortalMember]> = .idle
    private(set) var busy: String?
    var selected: Set<String> = []
    var query = ""
    var actionError: String?
    var notice: String?

    private let service: EquipmentService

    init(service: EquipmentService) {
        self.service = service
    }

    func loadAccess() async {
        canManage = (try? await service.access().canManage) ?? false
    }

    func loadMine() async { await fill(\.mine) { try await self.service.mine() } }
    func loadAvailable() async { await fill(\.available) { try await self.service.available() } }
    func loadRequests() async { await fill(\.requests) { try await self.service.managedRequests() } }
    func loadOut() async { await fill(\.out) { try await self.service.out() } }
    func loadInventory() async { await fill(\.inventory) { try await self.service.inventory() } }
    func loadManagers() async { await fill(\.managers) { try await self.service.managers() } }
    func loadMembers() async { await fill(\.members) { try await self.service.members() } }

    var matchingGear: [GearItem] {
        Self.search(available.value ?? [], query: query)
    }

    var selectedGear: [GearItem] {
        (available.value ?? []).filter { selected.contains($0.barcode) }
    }

    nonisolated static func search(_ items: [GearItem], query: String) -> [GearItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.barcode.localizedCaseInsensitiveContains(needle) }
    }

    func toggle(_ item: GearItem) {
        if selected.contains(item.barcode) { selected.remove(item.barcode) } else { selected.insert(item.barcode) }
    }

    /// Sends the request; on success clears the picks and refreshes both lists.
    func submitRequest(name: String, studentId: String, email: String) async -> Bool {
        let body = GearRequestBody(studentName: name.trimmingCharacters(in: .whitespaces),
                                   studentId: studentId.trimmingCharacters(in: .whitespaces),
                                   email: email.trimmingCharacters(in: .whitespaces),
                                   barcodes: selectedGear.map(\.barcode))
        busy = "request"
        defer { busy = nil }
        do {
            try await service.request(body)
            selected = []
            notice = "Requested. Equipment managers will review it."
            await loadAvailable()
            await loadMine()
            return true
        } catch {
            actionError = PortalError.gearRequestMessage(error)
            return false
        }
    }

    func decide(_ request: ManagedRequests.Request, approve: Bool) async {
        await act(request.id, done: approve ? "Approved. The items are held for them." : "Denied.") {
            try await self.service.decide(request.id, approve)
            await self.loadRequests()
        }
    }

    /// Force-return an item that's out, or release a hold nobody picked up.
    func clear(_ item: ManagedOut.Item) async {
        await act(item.id, done: item.checkedOut ? "Marked returned." : "Hold released.") {
            try await self.service.outAction(item.id, item.checkedOut ? "force-return" : "release-hold")
            await self.loadOut()
        }
    }

    // MARK: Inventory

    /// Adds an item; true when saved (the form then clears).
    func addItem(name: String, barcode: String) async -> Bool {
        let body = NewGearBody(name: name.trimmingCharacters(in: .whitespaces), barcode: barcode.trimmingCharacters(in: .whitespaces))
        guard !body.name.isEmpty, !body.barcode.isEmpty else { return false }
        return await inventoryChange("add", done: "Added \(body.name).", archiving: false) {
            try await self.service.addItem(body)
        }
    }

    func saveItem(_ item: ManagedOut.Item, name: String, barcode: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        let barcode = barcode.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !barcode.isEmpty else { return false }
        let body = GearPatchBody(id: item.id, name: name, barcode: barcode)
        return await inventoryChange(item.id, done: "Saved.", archiving: false) { try await self.service.updateItem(body) }
    }

    /// Archive only items that are in (not out or held), like the web.
    func archive(_ item: ManagedOut.Item) async {
        guard item.state == .in else { return }
        _ = await inventoryChange(item.id, done: "Archived \(item.name).", archiving: true) {
            try await self.service.updateItem(GearPatchBody(id: item.id, archived: true))
        }
    }

    private func inventoryChange(_ key: String, done: String, archiving: Bool,
                                 _ work: @escaping () async throws -> Void) async -> Bool {
        busy = key
        defer { busy = nil }
        do {
            try await work()
            notice = done
            await loadInventory()
            return true
        } catch {
            actionError = PortalError.inventoryMessage(error, archiving: archiving)
            return false
        }
    }

    // MARK: Managers

    func addManager(_ member: PortalMember) async {
        await act(member.id, done: "\(member.label) can now manage equipment.") {
            try await self.service.addManager(member.id)
            await self.loadManagers()
        }
    }

    func removeManager(_ row: ManagerRow) async {
        await act(row.id, done: "Removed \(row.label).") {
            try await self.service.removeManager(row.userId)
            await self.loadManagers()
        }
    }

    nonisolated static func searchItems(_ items: [ManagedOut.Item], query: String) -> [ManagedOut.Item] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.barcode.localizedCaseInsensitiveContains(needle) }
    }

    private func act(_ key: String, done: String, _ work: @escaping () async throws -> Void) async {
        busy = key
        defer { busy = nil }
        do {
            try await work()
            notice = done
        } catch {
            actionError = Loadable<GearItem>.message(for: error)
        }
    }

    private func fill<T: Sendable>(_ path: ReferenceWritableKeyPath<EquipmentModel, Loadable<T>>,
                                   _ load: @escaping () async throws -> T) async {
        if self[keyPath: path].value == nil { self[keyPath: path] = .loading }
        do {
            self[keyPath: path] = .loaded(try await load())
        } catch {
            if self[keyPath: path].value == nil { self[keyPath: path] = .failed(Loadable<T>.message(for: error)) }
        }
    }
}
