import SwiftUI

/// Equipment managers' tools, like the web's Manage tabs: Requests, Out, Inventory, Managers.
struct ManageGearView: View {
    enum Tab: Hashable { case requests, out, inventory, managers }

    let model: EquipmentModel
    @State private var tab: Tab = .requests

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(title: requestsTitle, selected: tab == .requests) { tab = .requests }
                    Chip(title: outTitle, selected: tab == .out) { tab = .out }
                    Chip(title: "Inventory", selected: tab == .inventory) { tab = .inventory }
                    Chip(title: "Managers", selected: tab == .managers) { tab = .managers }
                }
                .padding(.horizontal, Brand.gutter)
            }
            .padding(.bottom, 4)

            switch tab {
            case .requests: ManageRequestsView(model: model)
            case .out: ManageOutView(model: model)
            case .inventory: InventoryView(model: model)
            case .managers: GearManagersView(model: model)
            }
        }
        .task {
            // The chip counts (pending, overdue), like the web's tab badges.
            await model.loadRequests()
            await model.loadOut()
        }
    }

    private var requestsTitle: String {
        let pending = model.requests.value?.filter { $0.status == .pending }.count ?? 0
        return pending > 0 ? "Requests (\(pending))" : "Requests"
    }

    private var outTitle: String {
        let overdue = model.out.value?.filter { $0.isOverdue() }.count ?? 0
        return overdue > 0 ? "Out (\(overdue) overdue)" : "Out"
    }
}

/// Equipment managers: approve (holds the items) or deny requests; Pending or All, like the web.
struct ManageRequestsView: View {
    let model: EquipmentModel
    @AppStorage("equipment.requests.pendingOnly") private var pendingOnly = true

    var body: some View {
        ScrollView {
            LoadableView(model.requests, retry: { Task { await model.loadRequests() } }) { requests in
                let shown = pendingOnly ? requests.filter { $0.status == .pending } : requests
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Chip(title: "Pending", selected: pendingOnly) { pendingOnly = true }
                        Chip(title: "All (\(requests.count))", selected: !pendingOnly) { pendingOnly = false }
                    }
                    if shown.isEmpty {
                        EmptyStateView(title: pendingOnly ? "All caught up" : "No requests yet",
                                       message: pendingOnly ? "No equipment requests need a decision." : "Requests students send show up here.")
                    }
                    ForEach(shown) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(request.student.label).font(.lexend(16, .semibold, relativeTo: .headline))
                                    Text(request.email).font(.small).foregroundStyle(Brand.muted)
                                    Text(request.student.studentId).font(.mono(12)).foregroundStyle(Brand.muted)
                                }
                                Spacer()
                                StatusTag(text: request.word, tone: Self.tone(request))
                            }
                            ForEach(request.items, id: \.item.id) { line in
                                HStack {
                                    Text(line.item.name).font(.bodyText)
                                    Spacer()
                                    Text(line.item.barcode).font(.mono(12)).foregroundStyle(Brand.muted)
                                }
                            }
                            Text(FeatureDates.dayAndTime(request.createdAt)).font(.small).foregroundStyle(Brand.muted)
                            HStack(spacing: 8) {
                                if request.canDeny {
                                    Button("Deny") { Task { await model.decide(request, approve: false) } }
                                        .buttonStyle(.brandSecondary)
                                }
                                if request.canApprove {
                                    Button("Approve") { Task { await model.decide(request, approve: true) } }
                                        .buttonStyle(.brandPrimary)
                                }
                            }
                            .disabled(model.busy != nil)
                        }
                        .card(padding: 12)
                        .overlay { if model.busy == request.id { ProgressView() } }
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.loadRequests() }
    }

    static func tone(_ request: ManagedRequests.Request) -> StatusTag.Tone {
        if request.fulfilled { return .neutral }
        switch request.status {
        case .pending: return .warning
        case .approved: return .success
        case .denied: return .danger
        }
    }
}

/// Equipment managers: who has what, overdue flags, force-return or release a hold.
struct ManageOutView: View {
    let model: EquipmentModel
    @State private var confirming: ManagedOut.Item?
    @State private var filter: OutFilter = .all

    var body: some View {
        ScrollView {
            LoadableView(model.out, retry: { Task { await model.loadOut() } }) { items in
                let shown = items.filter { filter.includes($0) }
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(OutFilter.allCases, id: \.self) { option in
                                Chip(title: "\(option.title) \(items.filter { option.includes($0) }.count)", selected: filter == option) {
                                    filter = option
                                }
                            }
                        }
                    }
                    if shown.isEmpty {
                        EmptyStateView(title: filter == .all ? "Everything's in" : "Nothing here",
                                       message: filter == .all ? "No gear is out or on hold." : "No \(filter.title.lowercased()) items.")
                    }
                    ForEach(shown) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            GearRow(item: GearItem(id: item.id, name: item.name, barcode: item.barcode)) {
                                if item.isOverdue() {
                                    StatusTag(text: "Overdue", tone: .danger)
                                } else {
                                    StatusTag(text: item.checkedOut ? "Out" : "Held", tone: item.checkedOut ? .neutral : .success)
                                }
                            }
                            HStack {
                                Text(detail(item)).font(.small).foregroundStyle(Brand.secondary)
                                Spacer()
                                Button(item.checkedOut ? "Mark returned" : "Release hold") { confirming = item }
                                    .font(.lexend(14, .medium, relativeTo: .subheadline))
                                    .foregroundStyle(Brand.danger)
                                    .frame(minHeight: 44)
                                    .disabled(model.busy != nil)
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.loadOut() }
        .confirmationDialog(confirming?.checkedOut == true ? "Mark this returned?" : "Release this hold?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { item in
            Button(item.checkedOut ? "Mark returned" : "Release hold", role: .destructive) {
                Task { await model.clear(item) }
            }
        } message: { item in
            Text(item.checkedOut ? "Use this only when the item is back but wasn't scanned in." : "The item becomes available to everyone again.")
        }
    }

    private func detail(_ item: ManagedOut.Item) -> String {
        if item.checkedOut {
            var parts = [item.checkedOutBy?.label ?? "Unknown borrower"]
            if let at = item.checkedOutAt { parts.append("since \(FeatureDates.dayAndTime(at))") }
            if item.tookSdCard == true { parts.append("SD card") }
            return parts.joined(separator: " · ")
        }
        return "Held for \(item.onHoldForStudent?.label ?? "a student")"
    }
}
