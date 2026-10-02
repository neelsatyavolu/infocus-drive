import SwiftUI

/// One extension request: who and what, group agreement, producer approvals,
/// and the actions this viewer can take (agree/decline, approve/deny).
struct ExtensionRequestCard: View {
    let request: ExtensionRequest
    let viewerId: String
    let busy: Bool
    var onRespond: (Bool) -> Void = { _ in }
    var onApprove: () -> Void = {}
    var onDeny: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cycle \(request.cycleNumber) · \(ExtensionRequest.daysLabel(request.headlineDays))")
                    .headline(.h3)
                Spacer(minLength: 8)
                StatusTag(text: request.status.rawValue, tone: tone)
            }
            Text(request.groupTopic.isEmpty ? request.groupLabel : "\(request.groupLabel) · “\(request.groupTopic)”")
                .font(.small)
                .foregroundStyle(Brand.secondary)
            Text("\(request.producerGranted ? "Granted by" : "Requested by") \(request.student.name ?? request.student.email ?? "someone")")
                .font(.small)
                .foregroundStyle(Brand.muted)
            if request.approvals.contains(where: \.approved) {
                let terms = request.grantedTerms
                Text("Granted \(ExtensionRequest.daysLabel(terms.days)) to \(request.grantedUserIds.isEmpty ? "the whole group" : terms.userIds.map(request.memberName).joined(separator: ", "))")
                    .font(.small)
                    .foregroundStyle(Brand.foreground)
            }
            if !request.reason.isEmpty {
                Text("“\(request.reason)”")
                    .font(.bodyText)
                    .foregroundStyle(Brand.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !request.producerGranted {
                agreement
            }
            Text(request.progressLine + approvalNames)
                .font(.small)
                .foregroundStyle(Brand.muted)
            ForEach(request.denials, id: \.userId) { denial in
                Label("Denied by \(denial.name ?? "a producer"): “\(denial.reason)”", systemImage: "xmark.circle")
                    .font(.small)
                    .foregroundStyle(Brand.danger)
            }
            actions
        }
        .card()
    }

    private var tone: StatusTag.Tone {
        switch request.status {
        case .pending: .warning
        case .approved: .success
        case .denied: .danger
        }
    }

    private var approvalNames: String {
        request.approvals.isEmpty ? "" : " · " + request.approvals.map { "\($0.name ?? "Producer") \($0.approved ? "✓" : "✗")" }
            .joined(separator: ", ")
    }

    /// "Group agreement 1/2" and each member with ✓, ✗ or … (waiting).
    private var agreement: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Group agreement: \(request.agreedCount)/\(max(request.groupMembers.count, 1))")
                .font(.small)
                .foregroundStyle(Brand.muted)
            FlowRow(items: request.groupMembers.map { member in
                let consent = request.consent(of: member.userId)
                let mark = consent == nil ? "waiting" : (consent!.agreed ? "agreed" : "declined")
                return (member.name ?? member.email ?? "Unknown", mark)
            })
        }
    }

    @ViewBuilder private var actions: some View {
        if request.needsConsent(from: viewerId) {
            HStack(spacing: 8) {
                Button { onRespond(true) } label: { Label("I agree", systemImage: "checkmark") }
                    .buttonStyle(.brandPrimary)
                Button { onRespond(false) } label: { Label("Decline", systemImage: "xmark") }
                    .buttonStyle(.brandSecondary)
            }
            .disabled(busy)
        }
        if request.awaitsDecision {
            HStack(spacing: 8) {
                Button { onApprove() } label: { Label("Approve", systemImage: "checkmark") }
                    .buttonStyle(.brandPrimary)
                Button { onDeny() } label: { Label("Deny", systemImage: "xmark") }
                    .buttonStyle(.brandSecondary)
            }
            .disabled(busy || (!request.producerGranted && !request.memberConsentComplete))
            if !request.producerGranted && !request.memberConsentComplete {
                Text("Every group member must agree before producers can approve.")
                    .font(.small)
                    .foregroundStyle(Brand.muted)
            }
        }
        if busy {
            ProgressView().tint(Brand.green)
        }
    }
}

/// Members with their agreement, as small tags that wrap.
private struct FlowRow: View {
    let items: [(name: String, mark: String)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { tags }
            VStack(alignment: .leading, spacing: 6) { tags }
        }
    }

    @ViewBuilder private var tags: some View {
        ForEach(items, id: \.name) { item in
            HStack(spacing: 4) {
                Image(systemName: item.mark == "agreed" ? "checkmark" : item.mark == "declined" ? "xmark" : "ellipsis")
                    .font(.caption2)
                Text(item.name).font(.lexend(12, .medium, relativeTo: .caption))
            }
            .foregroundStyle(item.mark == "declined" ? Brand.danger : item.mark == "agreed" ? Brand.foreground : Brand.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(item.mark == "agreed" ? Brand.greenTint : Brand.raised, in: RoundedRectangle(cornerRadius: Brand.tagRadius))
            .accessibilityLabel("\(item.name), \(item.mark)")
        }
    }
}
