import Foundation
import Observation

/// One project: its folders, the media in the selected folder (page by page), and every
/// change to them. Each change goes to the Portal, then the list reloads.
@MainActor @Observable
final class ProjectModel {
    let projectId: String
    private(set) var shell: Loadable<ReviewProjectShell> = .idle
    private(set) var items: [ReviewMedia] = []
    private(set) var totalPages = 1
    private(set) var loadingItems = false
    private(set) var role: ReviewWorkspaceRole?
    var query: ReviewMediaQuery
    /// A failed action's words, shown in an alert.
    var actionError: String?
    private(set) var busyId: String?

    init(projectId: String, folderId: String?) {
        self.projectId = projectId
        query = ReviewMediaQuery(folderId: folderId)
    }

    var hasMore: Bool { query.page < totalPages }

    func load(_ api: ReviewAPI) async {
        if shell.value == nil { shell = .loading }
        do {
            async let roles = try? api.roles()
            let loaded = try await api.shell(projectId, nil)
            shell = .loaded(loaded)
            let access = await roles
            role = access?.first { $0.id == loaded.workspace.id }?.role
            await reloadItems(api)
        } catch PortalError.forbidden, PortalError.notFound {
            shell = .failed("This project isn't available to you.")
        } catch {
            if shell.value == nil { shell = .failed(Loadable<ReviewProjectShell>.message(for: error)) }
        }
    }

    /// First page again (after a change of folder, filter, sort or scope).
    func reloadItems(_ api: ReviewAPI) async {
        query.page = 1
        loadingItems = true
        defer { loadingItems = false }
        do {
            let page = try await api.media(projectId, query)
            items = page.items
            totalPages = page.totalPages
        } catch {
            items = []
            actionError = Loadable<Void>.message(for: error)
        }
    }

    func loadMore(_ api: ReviewAPI) async {
        guard hasMore, !loadingItems else { return }
        loadingItems = true
        defer { loadingItems = false }
        var next = query
        next.page += 1
        do {
            let page = try await api.media(projectId, next)
            query = next
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            totalPages = page.totalPages
        } catch {
            actionError = Loadable<Void>.message(for: error)
        }
    }

    // MARK: Changes

    func rename(_ item: ReviewMedia, to raw: String, api: ReviewAPI) async {
        guard let title = ReviewLogic.cleanTitle(raw) else {
            actionError = "Give it a title."
            return
        }
        await run(item.id, api) { try await api.rename(item.id, title) }
    }

    func delete(_ item: ReviewMedia, api: ReviewAPI) async {
        await run(item.id, api) { try await api.deleteMedia(item.id) }
    }

    func restore(_ item: ReviewMedia, api: ReviewAPI) async {
        await run(item.id, api) { try await api.restoreMedia(item.id) }
    }

    func deleteForever(_ item: ReviewMedia, api: ReviewAPI) async {
        await run(item.id, api) { try await api.deleteForever(item.id) }
    }

    func setApproval(_ item: ReviewMedia, to status: ReviewApproval, airedAt: Date?, api: ReviewAPI) async {
        guard let version = item.currentVersion else { return }
        await run(item.id, api) { try await api.setApproval(item.id, version.id, status, airedAt) }
    }

    func createFolder(_ raw: String, api: ReviewAPI) async {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(name.count) else {
            actionError = "Folder names are 1 to 120 characters."
            return
        }
        do {
            try await api.createFolder(projectId, name)
            shell = .loaded(try await api.shell(projectId, nil))
        } catch {
            actionError = Loadable<Void>.message(for: error)
        }
    }

    private func run(_ id: String, _ api: ReviewAPI, _ action: () async throws -> Void) async {
        busyId = id
        defer { busyId = nil }
        do {
            try await action()
            await reloadItems(api)
        } catch {
            actionError = Loadable<Void>.message(for: error)
        }
    }
}
