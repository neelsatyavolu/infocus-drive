import SwiftUI

/// Docked participation scores waiting for a second producer. You can approve
/// or deny other producers' requests, never your own (`canReview` from the Portal).
struct ParticipationRequestsSheet: View {
    @Environment(\.portalClient) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var state: Loadable<ParticipationRequests> = .idle
    @State private var deciding: String?
    @State private var error: String?

    private var service: GradeEditorService { GradeEditorService(client: client) }

    var body: some View {
        NavigationStack {
            LoadableView(state, retry: { Task { await load() } }) { payload in
                List {
                    if let error { GradeEditorError(message: error).listRowBackground(Color.clear) }
                    if payload.requests.isEmpty {
                        EmptyStateView(title: "Nothing pending", message: "Every docked score has been reviewed.")
                            .listRowBackground(Color.clear)
                    }
                    ForEach(payload.requests) { request in
                        Section {
                            ForEach(Array(request.items.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.displayName).font(.bodyText)
                                        Spacer()
                                        Text("\(item.points)").font(.mono(16, .medium))
                                    }
                                    Text("\(GradeEditorLogic.dayLabel(item.date)) · was \(item.currentPoints.map(String.init) ?? "not entered")")
                                        .font(.mono(12)).foregroundStyle(Brand.muted)
                                    if !item.notes.isEmpty { Text(item.notes).font(.small).foregroundStyle(Brand.secondary) }
                                }
                                .padding(.vertical, 4)
                            }
                            actions(request)
                        } header: {
                            Text("From \(request.requestedBy.displayName)").font(.small)
                        }
                        .listRowBackground(Brand.card)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .brandBackground()
            .navigationTitle("Pending approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    @ViewBuilder private func actions(_ request: ParticipationRequests.Request) -> some View {
        if request.canReview {
            HStack(spacing: 12) {
                Button("Deny") { Task { await decide(request.id, approved: false) } }
                    .buttonStyle(QuietDestructiveButtonStyle())
                Button("Approve") { Task { await decide(request.id, approved: true) } }
                    .buttonStyle(.brandPrimary)
            }
            .disabled(deciding != nil)
        } else {
            Text("Another producer has to review your own docked scores.")
                .font(.small).foregroundStyle(Brand.muted)
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await service.participationRequests()) } catch {
            state = .failed(Loadable<ParticipationRequests>.message(for: error))
        }
    }

    private func decide(_ requestId: String, approved: Bool) async {
        deciding = requestId
        error = nil
        defer { deciding = nil }
        do {
            try await service.decideParticipation(requestId: requestId, approved: approved)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } catch {
            self.error = Loadable<ParticipationRequests>.message(for: error)
        }
    }
}
