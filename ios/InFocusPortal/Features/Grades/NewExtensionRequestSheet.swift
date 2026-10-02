import SwiftUI

/// Request an extension for my package group. Teammates are asked to agree,
/// then two producers approve (`POST api/extensions/requests`).
struct NewExtensionRequestSheet: View {
    let service: GradesService
    let submit: (NewExtensionRequest) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cycle = 1
    @State private var days: Double = 1
    @State private var reason = ""
    @State private var saving = false
    @State private var error: String?

    /// `MAX_CYCLES_PER_SEMESTER`.
    static let maxCycle = 8

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Cycle", selection: $cycle) {
                        ForEach(1...Self.maxCycle, id: \.self) { Text("Cycle \($0)").tag($0) }
                    }
                    ExtensionDaysField(days: $days)
                } footer: {
                    Text("You must be on a package group for this cycle. Your teammates are asked to agree before producers review it.")
                }
                Section("Reason") {
                    TextField("Family emergency, unresolvable technical issue, …", text: $reason, axis: .vertical)
                        .lineLimit(3...8)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Brand.danger)
                    }
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Request an extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { Task { await send() } }
                        .disabled(saving || !ExtensionRequest.isValidDays(days))
                }
            }
            .task {
                if let current = await service.currentCycle(), (1...Self.maxCycle).contains(current) { cycle = current }
            }
        }
    }

    private func send() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await submit(NewExtensionRequest(cycleNumber: cycle, requestedDays: ExtensionRequest.roundDays(days),
                                                 reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)))
            dismiss()
        } catch {
            self.error = Loadable<ExtensionRequestsPayload>.message(for: error)
        }
    }
}
