import SwiftUI

/// Extension requests: students file and agree to them, producers approve or
/// deny (`api/extensions/requests`). Exec grants stay on the web.
struct ExtensionsScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @Environment(BadgeCenter.self) private var badges
    @Environment(Router.self) private var router
    @State private var model = ExtensionsModel()
    @State private var requesting = false
    @State private var approving: ExtensionRequest?
    @State private var denying: ExtensionRequest?
    @State private var showDenied = false

    private var service: GradesService { GradesService(client: client) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LoadableView(model.state, retry: { Task { await model.load(service) } }) { payload in
                    list(payload)
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.load(service) }
        .task { if model.state.value == nil { await model.load(service) } }
        .brandBackground()
        .navigationTitle(session.user?.isProducer == true ? "Extension requests" : "Extensions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $requesting) {
            NewExtensionRequestSheet(service: service) { request in
                try await model.submit(request, service: service, badges: badges)
            }
        }
        .modifier(ExtensionActions(model: model, service: service, badges: badges,
                                   approving: $approving, denying: $denying))
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if session.user?.doesStudentWork == true {
                Button { requesting = true } label: { Label("Request an extension", systemImage: "plus") }
            } else if model.state.value?.canGrant == true {
                Button { router.openPortal("extension-requests", title: "Extension requests") } label: {
                    Label("Grant an extension", systemImage: "plus")
                }
                .hiddenInSampleApp()
            }
        }
    }

    @ViewBuilder private func list(_ payload: ExtensionRequestsPayload) -> some View {
        if payload.requests.isEmpty {
            EmptyStateView(title: "No extension requests",
                           message: "Requests for your package groups show up here.",
                           actionTitle: session.user?.doesStudentWork == true ? "Request an extension" : nil,
                           action: session.user?.doesStudentWork == true ? { requesting = true } : nil)
        } else {
            section("Needs your response", payload.needingMe, payload)
            section(payload.needingMe.isEmpty ? "Requests" : "Other requests", payload.open, payload)
            if !payload.denied.isEmpty {
                DisclosureGroup(isExpanded: $showDenied) {
                    VStack(spacing: 12) { cards(payload.denied, payload) }
                        .padding(.top, 8)
                } label: {
                    Eyebrow("Denied (\(payload.denied.count))", color: Brand.muted)
                }
                .tint(Brand.secondary)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ requests: [ExtensionRequest], _ payload: ExtensionRequestsPayload) -> some View {
        if !requests.isEmpty {
            SectionHeader(title: title)
            cards(requests, payload)
        }
    }

    private func cards(_ requests: [ExtensionRequest], _ payload: ExtensionRequestsPayload) -> some View {
        ForEach(requests) { request in
            ExtensionRequestCard(request: request, payload: payload, model: model, service: service, badges: badges,
                                 approving: $approving, denying: $denying)
        }
    }
}

/// One request, opened from a notification or link (`/extension-requests/<id>`).
struct ExtensionRequestScreen: View {
    let id: String
    @Environment(\.portalClient) private var client
    @Environment(BadgeCenter.self) private var badges
    @State private var model = ExtensionsModel()
    @State private var approving: ExtensionRequest?
    @State private var denying: ExtensionRequest?

    private var service: GradesService { GradesService(client: client) }

    var body: some View {
        ScrollView {
            LoadableView(model.state, retry: { Task { await model.load(service) } }) { payload in
                if let request = payload.requests.first(where: { $0.id == id }) {
                    ExtensionRequestCard(request: request, payload: payload, model: model, service: service,
                                         badges: badges, approving: $approving, denying: $denying)
                } else {
                    EmptyStateView(title: "Request not found",
                                   message: "It may have been decided, or it belongs to a group you're not on.")
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.load(service) }
        .task { if model.state.value == nil { await model.load(service) } }
        .brandBackground()
        .navigationTitle("Extension request")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ExtensionActions(model: model, service: service, badges: badges,
                                   approving: $approving, denying: $denying))
    }
}
