import SwiftUI

/// Guest review links for a project: create (view or comment, optional passcode and
/// expiry), copy or share, and revoke. Workspace owners only; the Portal checks again.
struct ShareLinksScreen: View {
    let projectId: String
    @Environment(Router.self) private var router
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<[ReviewGuestLink]> = .idle
    @State private var permission: ReviewGuestLink.Permission = .comment
    @State private var passcode = ""
    @State private var expires = false
    @State private var expiry = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var busy = false
    @State private var notice: String?
    @State private var actionError: String?

    private var api: ReviewAPI { .resolve(client) }

    var body: some View {
        List {
            createSection
            Section("Links") {
                LoadableView(state, retry: { Task { await load() } }) { links in
                    if links.isEmpty {
                        Text("No share links yet.").font(.small).foregroundStyle(Brand.muted)
                    }
                    ForEach(links) { link in row(link) }
                }
            }
        }
        .font(.bodyText)
        .scrollContentBackground(.hidden)
        .brandBackground()
        .navigationTitle("Share links")
        .navigationBarTitleDisplayMode(.inline)
        .task { if state.value == nil { await load() } }
        .refreshable { await load() }
        .alert("Couldn't finish that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private var createSection: some View {
        Section {
            Picker("Guests can", selection: $permission) {
                Text("Comment").tag(ReviewGuestLink.Permission.comment)
                Text("Only view").tag(ReviewGuestLink.Permission.view)
            }
            SecureField("Passcode (optional, 4 to 40 characters)", text: $passcode)
            Toggle("Expires", isOn: $expires).tint(Brand.fill)
            if expires {
                DatePicker("On", selection: $expiry, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            }
            Button {
                Task { await create() }
            } label: {
                if busy { ProgressView().tint(Brand.onBrand) } else { Text("Create link") }
            }
            .buttonStyle(.brandPrimary)
            .disabled(busy || !passcodeOK)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            if let notice {
                Text(notice).font(.small).foregroundStyle(Brand.muted)
            }
        } header: {
            Text("New link")
        } footer: {
            Text("Anyone with a link can open this project's media without a Portal account.")
        }
    }

    private var passcodeOK: Bool { passcode.isEmpty || (4...40).contains(passcode.count) }

    @ViewBuilder
    private func row(_ link: ReviewGuestLink) -> some View {
        let url = router.portal.map { ReviewLogic.guestURL(token: link.token, portal: $0) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusTag(text: link.permission == .comment ? "Comment" : "View")
                if link.revokedAt != nil {
                    StatusTag(text: "Revoked", tone: .danger)
                } else if !link.isActive() {
                    StatusTag(text: "Expired", tone: .warning)
                }
                Spacer()
                Text(link.createdAt, format: .dateTime.month(.abbreviated).day()).font(.mono(12)).foregroundStyle(Brand.muted)
            }
            if let expiresAt = link.expiresAt {
                Text("Expires \(expiresAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .font(.small).foregroundStyle(Brand.secondary)
            }
            if link.isActive(), let url {
                HStack(spacing: 16) {
                    Button("Copy") {
                        UIPasteboard.general.url = url
                        notice = "Copied share link."
                    }
                    ShareLink(item: url) { Text("Share") }
                    Spacer()
                    Button("Revoke", role: .destructive) { Task { await revoke(link) } }
                }
                .buttonStyle(.borderless)
                .font(.lexend(14, .medium))
                .foregroundStyle(Brand.green)
                .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.guestLinks(projectId))
        } catch PortalError.forbidden {
            state = .failed("Only the workspace's owners can manage share links.")
        } catch {
            if state.value == nil { state = .failed(Loadable<[ReviewGuestLink]>.message(for: error)) }
        }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            try await api.createGuestLink(NewGuestLink(projectId: projectId, permission: permission,
                                                      passcode: passcode.isEmpty ? nil : passcode, expiresAt: expires ? expiry : nil))
            passcode = ""
            expires = false
            notice = "Share link created."
            await load()
        } catch {
            actionError = Loadable<Void>.message(for: error)
        }
    }

    private func revoke(_ link: ReviewGuestLink) async {
        do {
            try await api.revokeGuestLink(link.id)
            notice = "Share link revoked."
            await load()
        } catch {
            actionError = Loadable<Void>.message(for: error)
        }
    }
}
