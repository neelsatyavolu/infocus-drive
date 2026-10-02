import Foundation
import Observation

/// The shared PA script for the next PA date: the same load / save / regenerate rules as
/// `/announcements/pa`. Saves carry the script version, so someone else's newer save is
/// never overwritten (the Portal answers with what to do instead).
@MainActor @Observable
final class PAEditorModel {
    enum Activity: Equatable { case loading, saving, regenerating }

    private(set) var state: Loadable<PAPage> = .idle
    private(set) var activity: Activity?
    private(set) var saved = false
    var draft = ""
    var error: String?

    var page: PAPage? { state.value }

    /// Edits that aren't saved yet.
    var dirty: Bool {
        guard let script = page?.script else { return false }
        return draft != script.content
    }

    var canEdit: Bool { page?.canEdit == true && page?.script != nil }
    var canSave: Bool { canEdit && dirty && activity == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canRegenerate: Bool { canEdit && activity == nil }
    /// Refreshing would throw away edits, so it waits until they're saved or discarded.
    var canRefresh: Bool { activity == nil && !dirty }

    var statusText: String {
        switch activity {
        case .regenerating: return "Regenerating…"
        case .saving: return "Saving…"
        default: break
        }
        if dirty { return "Unsaved changes" }
        if saved { return "Saved" }
        return canEdit ? "Shared script" : "Read only"
    }

    func load(api: AnnouncementsAPI, force: Bool = false) async {
        if !force, state.value != nil || state.isLoading { return }
        guard !dirty else { return }
        if state.value == nil { state = .loading }
        activity = .loading
        error = nil
        saved = false
        defer { activity = nil }
        do {
            apply(try await api.pa())
        } catch {
            if state.value == nil { state = .failed(Loadable<PAPage>.message(for: error)) }
            else { self.error = Self.message(for: error, fallback: "Could not load the PA script.") }
        }
    }

    func save(api: AnnouncementsAPI) async {
        guard canSave, let date = page?.date, let version = page?.script?.version else { return }
        activity = .saving
        error = nil
        saved = false
        defer { activity = nil }
        do {
            apply(try await api.savePA(date, draft, version))
            saved = true
        } catch {
            self.error = Self.message(for: error, fallback: "Could not save the PA script. Your draft is still here.")
        }
    }

    /// Replaces the shared script (and any unsaved edits) with a fresh one from the latest
    /// announcements and assigned names.
    func regenerate(api: AnnouncementsAPI) async {
        guard canRegenerate, let date = page?.date, let version = page?.script?.version else { return }
        activity = .regenerating
        error = nil
        saved = false
        defer { activity = nil }
        do {
            apply(try await api.regeneratePA(date, version))
            saved = true
        } catch {
            self.error = Self.message(for: error, fallback: "Could not regenerate the PA script. Your draft is still here.")
        }
    }

    func discard() {
        draft = page?.script?.content ?? ""
        saved = false
    }

    private func apply(_ next: PAPage) {
        state = .loaded(next)
        draft = next.script?.content ?? ""
    }

    /// The Portal's own words, including its 503 "No announcements could be loaded…" and the
    /// 409 "The script changed since you opened it…" (generic text only when it sent none).
    nonisolated static func message(for error: Error, fallback: String) -> String {
        if case PortalError.server(_, let message) = error, !message.isEmpty { return message }
        return (error as? LocalizedError)?.errorDescription ?? fallback
    }
}
