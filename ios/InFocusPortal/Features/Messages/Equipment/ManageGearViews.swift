import SwiftUI

/// Equipment managers: approve (holds the items) or deny requests.
struct ManageRequestsView: View {
    let model: EquipmentModel

    var body: some View {
        ScrollView {
            LoadableView(model.requests, retry: { Task { await model.loadRequests() } }) { requests in
                let open = requests.filter { $0.canApprove || $0.canDeny }
                VStack(alignment: .leading, spacing: 10) {
                    if open.isEmpty {
                        EmptyStateView(title: "All caught up", message: "No equipment requests need a decision.")
                    }
                    ForEach(open) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(request.student.label).font(.lexend(16, .semibold, relativeTo: .headline))
                                    Text(request.email).font(.small).foregroundStyle(Brand.muted)
                                }
                                Spacer()
                                StatusTag(text: request.status.word, tone: request.status == .pending ? .warning : .success)
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
        .task { await model.loadRequests() }
    }
}

/// Equipment managers: who has what, overdue flags, force-return or release a hold.
struct ManageOutView: View {
    let model: EquipmentModel
    @State private var confirming: ManagedOut.Item?

    var body: some View {
        ScrollView {
            LoadableView(model.out, retry: { Task { await model.loadOut() } }) { items in
                VStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty {
                        EmptyStateView(title: "Everything's in", message: "No gear is out or on hold.")
                    }
                    ForEach(items) { item in
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
        .task { await model.loadOut() }
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
