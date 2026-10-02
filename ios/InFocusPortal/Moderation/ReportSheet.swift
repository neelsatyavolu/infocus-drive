import SwiftUI

/// "Report message": what's being reported, an optional reason, and Report.
struct ReportSheet: View {
    let target: ReportTarget
    @Environment(\.portalClient) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var sending = false
    @State private var error: String?
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(target.authorName).font(.lexend(14, .semibold))
                        Text(target.excerpt).font(.bodyText).foregroundStyle(Brand.secondary).lineLimit(6)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Reporting")
                } footer: {
                    Text("The InFocus adviser and executive producers see who reported it, who wrote it and what it says.")
                }
                Section("Reason (optional)") {
                    TextField("What's wrong with it?", text: $reason, axis: .vertical)
                        .lineLimit(2...5)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.small)
                        .foregroundStyle(Brand.danger)
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Report message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Reporting…" : "Report") { Task { await send() } }
                        .disabled(sending)
                }
            }
            .alert(ContentReporter.confirmation, isPresented: $sent) {
                Button("OK") { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() async {
        sending = true
        error = nil
        defer { sending = false }
        var report = target.report
        report.reason = ContentReporter.reason(reason)
        do {
            try await ContentReporter.send(report, client: client)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            sent = true
        } catch {
            self.error = Loadable<Void>.message(for: error)
        }
    }
}
