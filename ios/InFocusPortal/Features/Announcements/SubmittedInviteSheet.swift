import SwiftUI
import UIKit

/// Executives: a link that lets people view submitted announcements without signing in,
/// copied or emailed (up to 20 addresses), valid for 30 days or a year.
struct SubmittedInviteSheet: View {
    let api: AnnouncementsAPI

    @Environment(\.dismiss) private var dismiss
    @State private var emails = ""
    @State private var duration: InviteDuration = .thirtyDays
    @State private var busy = false
    @State private var shareURL: String?
    @State private var note: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Link lasts", selection: $duration) {
                        ForEach(InviteDuration.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Link lasts")
                } footer: {
                    Text("Send a link so people can see submitted announcements without signing in.")
                }
                Section("Email to (optional)") {
                    TextField("name@school.org, name@school.org", text: $emails, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .lineLimit(2...5)
                }
                Section {
                    Button { Task { await create(sendEmail: false) } } label: {
                        Label("Create and copy link", systemImage: "link")
                    }
                    Button { Task { await create(sendEmail: true) } } label: {
                        Label("Email invites", systemImage: "paperplane")
                    }
                    .disabled(emails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(busy)
                if let shareURL {
                    Section("Link") {
                        Text(shareURL).font(.mono(13)).textSelection(.enabled)
                        ShareLink(item: shareURL) { Label("Share link", systemImage: "square.and.arrow.up") }
                    }
                }
                if let note {
                    Section { Text(note).font(.small).foregroundStyle(Brand.secondary) }
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .tint(Brand.green)
            .navigationTitle("Invite viewers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if busy { ToolbarItem(placement: .principal) { ProgressView() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func create(sendEmail: Bool) async {
        busy = true
        note = nil
        defer { busy = false }
        do {
            let invite = try await api.invite(emails, sendEmail, duration)
            shareURL = invite.shareUrl
            if sendEmail {
                if let sent = invite.emailed, sent > 0 {
                    note = "Sent \(sent) invite\(sent == 1 ? "" : "s")."
                } else {
                    note = "Link created. Email isn't set up, so copy the link instead."
                }
            } else {
                UIPasteboard.general.string = invite.shareUrl
                note = "Link copied."
            }
        } catch {
            note = Loadable<Bool>.message(for: error)
        }
    }
}
