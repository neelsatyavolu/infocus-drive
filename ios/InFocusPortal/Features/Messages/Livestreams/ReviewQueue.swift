import SwiftUI

/// Livestream managers: approve (adds them to the crew) or deny each pending request.
struct ReviewQueue: View {
    let schedule: LivestreamSchedule
    let model: LivestreamsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if schedule.pendingSignups.isEmpty {
                EmptyStateView(title: "All caught up", message: "No sign-up requests are waiting.")
            }
            ForEach(schedule.pendingSignups) { request in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Avatar(name: request.user?.name ?? "Member", size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.user?.name ?? "Member").font(.lexend(16, .semibold, relativeTo: .headline))
                            Text(request.event?.title ?? schedule.event(request.eventId)?.title ?? "Livestream")
                                .font(.small).foregroundStyle(Brand.secondary)
                        }
                    }
                    if let starts = request.event?.startsAt {
                        Text(FeatureDates.dayAndTime(starts)).font(.small).foregroundStyle(Brand.muted)
                    }
                    if !request.availableFullEvent {
                        StatusTag(text: "Partial availability", tone: .warning)
                    }
                    if let note = request.note, !note.isEmpty {
                        Text("“\(note)”").font(.small).foregroundStyle(Brand.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Deny") { Task { await model.review(request, approve: false) } }
                            .buttonStyle(.brandSecondary)
                        Button("Approve") { Task { await model.review(request, approve: true) } }
                            .buttonStyle(.brandPrimary)
                    }
                    .disabled(model.busy != nil)
                    .overlay { if model.busy == request.id { ProgressView() } }
                }
                .card(padding: 12)
            }
        }
    }
}

extension View {
    /// The action result alerts every livestream screen shares.
    func livestreamAlerts(_ model: LivestreamsModel?) -> some View {
        alert("Couldn't do that", isPresented: Binding(
            get: { model?.actionError != nil }, set: { if !$0 { model?.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model?.actionError ?? "")
        }
        .sensoryFeedback(.success, trigger: model?.notice)
    }
}
