import SwiftUI

/// Admin → Access requests: approve or deny people who asked to sign in, one at a
/// time or all pending at once. The Portal emails each person its decision.
struct AccessRequestsScreen: View {
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<[AccessRequest]> = .idle
    @State private var notAvailable = false
    @State private var busyId: String?
    @State private var actionError: String?
    @State private var confirmingAll = false
    @State private var denying: AccessRequest?
    @State private var notice: String?

    private var service: AdminService { AdminService(client: client) }

    var body: some View {
        Group {
            if notAvailable {
                NotAvailableView(message: "Access requests are for executive producers and up.")
            } else {
                LoadableView(state, retry: { Task { await load() } }) { requests in
                    list(requests)
                }
            }
        }
        .brandBackground()
        .navigationTitle("Access requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Approve all") { confirmingAll = true }
                    .disabled((state.value?.filter(\.isPending).count ?? 0) == 0 || busyId != nil)
            }
        }
        .confirmationDialog("Approve every pending request?", isPresented: $confirmingAll, titleVisibility: .visible) {
            Button("Approve all") { Task { await approveAll() } }
        } message: {
            Text("Each person can sign in right away and gets an email.")
        }
        .confirmationDialog("Deny \(denying?.label ?? "this request")?", isPresented: Binding(
            get: { denying != nil }, set: { if !$0 { denying = nil } }), titleVisibility: .visible) {
            Button("Deny", role: .destructive) {
                if let request = denying { Task { await decide(request, approve: false) } }
            }
        } message: {
            Text("They get an email saying the request was denied.")
        }
        .actionErrorAlert($actionError)
        .task { await load() }
    }

    private func list(_ requests: [AccessRequest]) -> some View {
        let pending = requests.filter(\.isPending)
        let decided = requests.filter { !$0.isPending }
        return List {
            if let notice {
                Text(notice).font(.small).foregroundStyle(Brand.green)
            }
            Section("Pending") {
                if pending.isEmpty {
                    Text("No one is waiting.").foregroundStyle(Brand.secondary)
                }
                ForEach(pending) { request in
                    PendingRequestRow(request: request, busy: busyId == request.id,
                                      approve: { Task { await decide(request, approve: true) } },
                                      deny: { denying = request })
                }
            }
            if !decided.isEmpty {
                Section("Decided") {
                    ForEach(decided) { request in
                        HStack {
                            PersonLine(title: request.label, detail: request.email)
                            StatusTag(text: request.status == "APPROVED" ? "Approved" : "Denied",
                                      tone: request.status == "APPROVED" ? .success : .neutral)
                        }
                    }
                }
            }
        }
        .toolsList()
        .refreshable { await load() }
    }

    private func load() async {
        await ToolLoad.run($state, notAvailable: $notAvailable) { try await service.accessRequests() }
    }

    private func decide(_ request: AccessRequest, approve: Bool) async {
        busyId = request.id
        defer { busyId = nil }
        do {
            try await service.decide(request.id, approve: approve)
            notice = approve ? "\(request.label) can sign in now." : "Denied \(request.label)."
            await load()
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }

    private func approveAll() async {
        busyId = "all"
        defer { busyId = nil }
        do {
            let count = try await service.approveAllPending()
            notice = count == 1 ? "Approved 1 request." : "Approved \(count) requests."
            await load()
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }
}

private struct PendingRequestRow: View {
    let request: AccessRequest
    let busy: Bool
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PersonLine(title: request.label, detail: request.email, busy: busy)
            Text("Asked \(AdminFormat.when(request.requestedAt))").font(.small).foregroundStyle(Brand.muted)
            HStack(spacing: 8) {
                Button("Approve", action: approve).buttonStyle(.brandPrimary)
                Button("Deny", action: deny).buttonStyle(QuietDestructiveButtonStyle())
            }
            .disabled(busy)
        }
        .padding(.vertical, 6)
    }
}
