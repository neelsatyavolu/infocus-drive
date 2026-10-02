import SwiftUI

/// Approve: the first approving producer picks the days and who gets them;
/// later approvals accept those terms as they are.
struct ApproveExtensionSheet: View {
    let request: ExtensionRequest
    let viewerId: String
    /// `terms` is nil when another producer already set them.
    let onConfirm: (_ terms: (days: Double, userIds: [String])?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var days: Double = 1
    @State private var selected: Set<String> = []
    @State private var saving = false

    var body: some View {
        let locked = request.lockedTerms(for: viewerId)
        NavigationStack {
            Form {
                Section {
                    Text("Cycle \(request.cycleNumber) · \(request.groupLabel). Asked for \(ExtensionRequest.daysLabel(request.requestedDays)).")
                        .font(.bodyText)
                }
                if let locked {
                    Section("Terms set by another producer") {
                        LabeledContent("Days", value: ExtensionRequest.daysLabel(locked.days))
                        LabeledContent("For", value: locked.userIds.map(request.memberName).joined(separator: ", "))
                    }
                } else {
                    Section("Grant") {
                        ExtensionDaysField(days: $days)
                    }
                    Section("Who gets it") {
                        ForEach(request.groupMembers, id: \.userId) { member in
                            Toggle(member.name ?? member.email ?? "Unknown", isOn: Binding(
                                get: { selected.contains(member.userId) },
                                set: { on in if on { selected.insert(member.userId) } else { selected.remove(member.userId) } }
                            ))
                            .tint(Brand.fill)
                        }
                    }
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Approve extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") {
                        Task {
                            saving = true
                            let terms = locked == nil ? (days: ExtensionRequest.roundDays(days),
                                                         userIds: request.groupMembers.map(\.userId).filter(selected.contains)) : nil
                            if await onConfirm(terms) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving || (locked == nil && (selected.isEmpty || !ExtensionRequest.isValidDays(days))))
                }
            }
            .onAppear {
                let start = request.approvals.contains(where: \.approved) ? request.grantedTerms
                    : (days: request.requestedDays, userIds: request.groupMembers.map(\.userId))
                days = start.days
                selected = Set(start.userIds)
            }
        }
    }
}

/// Deny: producers must say why (the group sees it).
struct DenyExtensionSheet: View {
    let request: ExtensionRequest
    let onConfirm: (_ reason: String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Cycle \(request.cycleNumber) · \(request.groupLabel) · \(ExtensionRequest.daysLabel(request.requestedDays))")
                        .font(.bodyText)
                }
                Section {
                    TextField("Why it's denied", text: $reason, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Reason")
                } footer: {
                    Text("The group sees this.")
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Deny extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Deny", role: .destructive) {
                        Task {
                            saving = true
                            if await onConfirm(reason.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Days with one decimal place (0.1 to 30): a stepper plus typing.
struct ExtensionDaysField: View {
    @Binding var days: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Rounded every step: 0.1 + 0.5 must be 0.6, not 0.6000000000000001.
            Stepper {
                HStack {
                    Text("Days")
                    Spacer()
                    TextField("Days", value: $days, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.mono(17, .medium))
                        .frame(width: 70)
                        .accessibilityLabel("Days")
                }
            } onIncrement: {
                days = ExtensionRequest.roundDays(days + 0.5)
            } onDecrement: {
                days = ExtensionRequest.roundDays(days - 0.5)
            }
            if !ExtensionRequest.isValidDays(days) {
                Label(ExtensionRequest.daysError, systemImage: "exclamationmark.circle")
                    .font(.small)
                    .foregroundStyle(Brand.danger)
            }
        }
    }
}
