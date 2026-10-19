import Foundation
import Observation

/// The teleprompter's scripts and every edit the web page makes: new, rename and delete scripts;
/// add, edit and delete sections; reformat a section or the whole script; refetch A2's bulletin.
/// Errors stay on screen in the Portal's words.
@MainActor @Observable
final class TeleprompterModel {
    private(set) var state: Loadable<TeleprompterPayload> = .idle
    var selectedId: String?
    private(set) var working = false
    /// The section (or "doc") being reformatted or refetched.
    private(set) var jobTarget: String?
    var error: String?

    private let api: TeleprompterAPI
    private let showDate: String?
    private let docId: String?

    init(api: TeleprompterAPI, showDate: String?, docId: String?) {
        self.api = api
        self.showDate = showDate
        self.docId = docId
    }

    var payload: TeleprompterPayload? { state.value }
    var docs: [TeleprompterDoc] { TeleprompterScript.sorted(payload?.docs ?? []) }
    var selected: TeleprompterDoc? { payload?.docs.first { $0.id == selectedId } }
    var canEdit: Bool { payload?.canEdit ?? false }
    var nextShowKey: String? { showDate == nil ? TeleprompterScript.showDateKey(payload?.nextShowDateIso) : nil }

    func load() async {
        if state.value == nil { state = .loading }
        do {
            let next = try await api.load(showDate)
            state = .loaded(next)
            if selectedId == nil || !next.docs.contains(where: { $0.id == selectedId }) {
                selectedId = TeleprompterScript.initial(next.docs, docId: docId, showDate: showDate, nextShowIso: next.nextShowDateIso)?.id
            }
        } catch PortalError.forbidden {
            state = .failed("The teleprompter isn't available for this account.")
        } catch {
            if state.value == nil { state = .failed(Loadable<TeleprompterPayload>.message(for: error)) }
            else { self.error = Loadable<TeleprompterPayload>.message(for: error) }
        }
    }

    // MARK: Scripts

    /// A new script, or the selected one renamed. Returns false when it wasn't saved.
    @discardableResult
    func saveDoc(title rawTitle: String, renaming id: String?) async -> Bool {
        let title = String(rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TeleprompterScript.titleMax))
        guard !title.isEmpty else { return false }
        return await run {
            if let id {
                let renamed = try await self.api.renameDoc(id, title)
                self.updateDocs { docs in docs.map { $0.id == renamed.id ? self.retitled($0, renamed.title) : $0 } }
            } else {
                guard let workspace = self.payload?.workspaceId, !workspace.isEmpty else {
                    throw EditError("Join a workspace before creating a script.")
                }
                let created = try await self.api.createDoc(workspace, title)
                self.updateDocs { $0 + [created] }
                self.selectedId = created.id
            }
        }
    }

    func deleteDoc(_ id: String) async {
        await run {
            try await self.api.deleteDoc(id)
            self.updateDocs { $0.filter { $0.id != id } }
            if self.selectedId == id { self.selectedId = self.docs.first?.id }
        }
    }

    func reformatDoc(_ id: String) async {
        jobTarget = "doc"
        defer { jobTarget = nil }
        await run {
            let updated = try await self.api.reformatDoc(id)
            self.updateDocs { docs in docs.map { $0.id == updated.id ? updated : $0 } }
        }
    }

    // MARK: Sections

    /// Adds a section to the selected script (`id` nil) or saves one. Returns false when it wasn't saved.
    @discardableResult
    func saveSection(id: String?, label rawLabel: String, content: String) async -> Bool {
        let label = String(rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TeleprompterScript.labelMax))
        guard !label.isEmpty else {
            error = "Give the section a label, like A1."
            return false
        }
        guard content.count <= TeleprompterScript.contentMax else {
            error = "Keep a section under \(TeleprompterScript.contentMax) characters."
            return false
        }
        guard let docId = selectedId else { return false }
        return await run {
            if let id {
                let updated = try await self.api.updateSection(id, label, content)
                self.replace(updated, in: docId)
            } else {
                let created = try await self.api.addSection(docId, label, content)
                self.updateDoc(docId) { $0.sections.append(created) }
            }
        }
    }

    func deleteSection(_ id: String) async {
        guard let docId = selectedId else { return }
        await run {
            try await self.api.deleteSection(id)
            self.updateDoc(docId) { $0.sections.removeAll { $0.id == id } }
        }
    }

    func runJob(_ job: TeleprompterAPI.SectionJob, on section: TeleprompterSection) async {
        guard let docId = selectedId else { return }
        jobTarget = section.id
        defer { jobTarget = nil }
        await run {
            let updated = try await self.api.sectionJob(section.id, job)
            self.replace(updated, in: docId)
        }
    }

    /// The next free "A<n>" label, as the Portal names a section left blank.
    func nextLabel() -> String { "A\((selected?.sections.count ?? 0) + 1)" }

    // MARK: -

    @discardableResult
    private func run(_ operation: @escaping () async throws -> Void) async -> Bool {
        guard !working else { return false }
        working = true
        error = nil
        defer { working = false }
        do {
            try await operation()
            return true
        } catch {
            self.error = CalendarDayEditor.message(for: error)
            return false
        }
    }

    private func updateDocs(_ change: ([TeleprompterDoc]) -> [TeleprompterDoc]) {
        guard var payload = state.value else { return }
        payload.docs = change(payload.docs)
        state = .loaded(payload)
    }

    private func updateDoc(_ id: String, _ change: (inout TeleprompterDoc) -> Void) {
        updateDocs { docs in
            docs.map { doc in
                guard doc.id == id else { return doc }
                var copy = doc
                change(&copy)
                return copy
            }
        }
    }

    private func replace(_ section: TeleprompterSection, in docId: String) {
        updateDoc(docId) { doc in
            doc.sections = doc.sections.map { $0.id == section.id ? section : $0 }
        }
    }

    private func retitled(_ doc: TeleprompterDoc, _ title: String) -> TeleprompterDoc {
        var copy = doc
        copy.title = title
        return copy
    }
}
