import SwiftUI
import WebKit

/// Admin → View as (super admin): see the whole app as someone else, then stop.
/// The Portal answers with a View as cookie; it goes into the cookie store the
/// native client and every web view share, then the app reloads who's signed in.
struct ViewAsScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(BadgeCenter.self) private var badges
    @State private var state: Loadable<[ViewAsPerson]> = .idle
    @State private var notAvailable = false
    @State private var status: ViewAsStatus?
    @State private var query = ""
    @State private var picked: ViewAsPerson?
    @State private var switching = false
    @State private var actionError: String?

    var body: some View {
        Group {
            if notAvailable {
                NotAvailableView(message: "View as is for the super admin.")
            } else {
                LoadableView(state, retry: { Task { await load() } }) { people in
                    list(people)
                }
            }
        }
        .brandBackground()
        .navigationTitle("View as")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Name or email")
        .disabled(switching)
        .confirmationDialog("View the Portal as \(picked?.label ?? "")?",
                            isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                            titleVisibility: .visible) {
            Button("View as \(picked?.label ?? "")") {
                if let person = picked { Task { await switchTo(person.id) } }
            }
        } message: {
            Text("The whole app shows what they see until you stop. Changes you make are saved as you.")
        }
        .actionErrorAlert($actionError)
        .task { await load() }
    }

    private func list(_ people: [ViewAsPerson]) -> some View {
        List {
            if let status, status.active {
                ViewAsActiveSection(status: status, stopping: switching) { Task { await switchTo(nil) } }
            }
            Section("People") {
                ForEach(ViewAsSwitch.filter(people, query)) { person in
                    Button { picked = person } label: {
                        PersonLine(title: person.label, detail: person.email)
                    }
                }
            }
        }
        .toolsList()
        .overlay { if switching { ProgressView().controlSize(.large) } }
        .refreshable { await load() }
    }

    /// The status says if this person may use View as at all (no more guessing from a 403),
    /// then the people list loads.
    private func load() async {
        let service = AdminService(client: client)
        status = try? await service.viewAsStatus()
        if let status, !status.allowed {
            notAvailable = true
            return
        }
        await ToolLoad.run($state, notAvailable: $notAvailable) { try await service.viewAsPeople() }
    }

    /// Switch (or stop with nil), then reload the signed-in person and start over on Home.
    private func switchTo(_ userId: String?) async {
        switching = true
        defer { switching = false }
        do {
            try await ViewAsSwitch.apply(userId, client: client, session: session, router: router, badges: badges)
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }
}

/// `POST api/auth/view-as` and its cookie (`infocus_view_as`, set or cleared by the Portal).
enum ViewAsSwitch {
    static let cookieName = "infocus_view_as"

    static func filter(_ people: [ViewAsPerson], _ query: String) -> [ViewAsPerson] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return people }
        return people.filter { [$0.name, $0.email].contains { $0?.lowercased().contains(needle) == true } }
    }

    /// Switch (or stop with nil), then reload the signed-in person, start over on Home and
    /// refresh the badges: every screen now shows the new account.
    @MainActor
    static func apply(_ userId: String?, client: PortalClient, session: SessionStore,
                      router: Router, badges: BadgeCenter) async throws {
        try await switchTo(userId, client: client)
        await session.load(using: client)
        router.reset()
        await badges.refresh(using: client)
    }

    static func isActive(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        cookie.name == cookieName && !cookie.value.isEmpty && (cookie.expiresDate ?? .distantFuture) > now
    }

    /// The body: `{ "userId": "…" }`, or `{ "userId": null }` to stop.
    static func body(_ userId: String?) throws -> Data {
        struct Body: Encodable {
            let userId: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(userId, forKey: .userId)
            }
            enum CodingKeys: String, CodingKey { case userId }
        }
        return try PortalJSON.encoder().encode(Body(userId: userId))
    }

    static func switchTo(_ userId: String?, client: PortalClient) async throws {
        if SampleMode.isOn { throw PortalError.sampleApp }
        let request = await client.request("POST", "api/auth/view-as", body: try body(userId))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await PortalClient.urlSession.data(for: request)
        } catch let error as URLError {
            throw PortalError.from(error)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PortalError.from(status: status, message: PortalJSON.errorMessage(data))
        }
        let headers = (http?.allHeaderFields as? [String: String]) ?? [:]
        let cookies = request.url.map { HTTPCookie.cookies(withResponseHeaderFields: headers, for: $0) } ?? []
        await store(cookies.filter { $0.name == cookieName }, portal: client.portal)
    }

    /// Clears any old View as cookie, then keeps the new one if the Portal set one.
    @MainActor
    private static func store(_ cookies: [HTTPCookie], portal: URL) async {
        let jar = WKWebsiteDataStore.default().httpCookieStore
        for old in await PortalCookies.forPortal(portal) where old.name == cookieName {
            await jar.deleteCookie(old)
        }
        for cookie in cookies where isActive(cookie) {
            await jar.setCookie(cookie)
        }
    }
}
