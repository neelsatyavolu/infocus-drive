import SwiftUI
import UIKit

/// Submit an announcement (`/submit-announcement`): anyone can ask for an announcement on InFocus
/// and the Friday Schoology update; InFocus reviews every request before it airs.
struct SubmitAnnouncementView: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @State private var draft = AnnouncementForm.Draft()
    @State private var sending = false
    @State private var error: String?
    @State private var submitted = false
    @State private var prefilled = false
    @FocusState private var announcementFocused: Bool

    var body: some View {
        Form {
            Section {
                Nameplate(eyebrow: "InFocus · Schoology", title: "Submit an announcement",
                          subtitle: "InFocus reviews every request.")
                    .listRowInsets(EdgeInsets())
            }
            if submitted { success } else { form }
        }
        .font(.bodyText)
        .scrollContentBackground(.hidden)
        .brandBackground()
        .navigationTitle("Submit")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prefill)
    }

    // MARK: Form

    @ViewBuilder
    private var form: some View {
        Section {
            LabeledContent("Runs on", value: "InFocus (Wednesday and Friday broadcasts) and the Friday Schoology update")
            LabeledContent("Schoology deadline", value: "4 p.m. Thursday")
        } header: {
            Text("How it works")
        }
        .font(.small)

        Section("1 · About you") {
            TextField("Email", text: $draft.email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Full name", text: $draft.name)
                .textContentType(.name)
            Picker("Which best describes you?", selection: $draft.submitterKind) {
                Text("Select one").tag(SubmitterKind?.none)
                ForEach(SubmitterKind.allCases) { Text($0.label).tag(Optional($0)) }
            }
        }

        Section {
            Picker("Where should this run?", selection: $draft.runOn) {
                Text("Select one").tag(RunOn?.none)
                ForEach(RunOn.allCases) { Text($0.label).tag(Optional($0)) }
            }
            TextField("Write the announcement as it should be read or posted.", text: $draft.announcement, axis: .vertical)
                .lineLimit(6...14)
                .focused($announcementFocused)
            TextField("Photo or media Google Drive link", text: $draft.mediaLink)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Anything else we should know?", text: $draft.moreInfo, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text("2 · Announcement")
        } footer: {
            Text("\(draft.announcement.trimmingCharacters(in: .whitespacesAndNewlines).count) / \(AnnouncementForm.maxAnnouncementChars)")
                .font(.mono(12))
                .foregroundStyle(characterCountColor)
                .accessibilityLabel("\(draft.announcement.count) of \(AnnouncementForm.maxAnnouncementChars) characters")
        }

        Section {
            DatePicker("Start date", selection: startBinding, displayedComponents: .date)
            DatePicker("End date", selection: endBinding, in: (draft.startDate ?? .distantPast)..., displayedComponents: .date)
        } header: {
            Text("3 · When it runs")
        } footer: {
            Text("Maximum \(AnnouncementForm.maxShowDays) consecutive show days.")
        }

        Section("4 · Submit") {
            Toggle(isOn: $draft.policyAgreed) {
                Text("I agree to the InFocus announcement policy. Announcements run for a maximum of four consecutive show days. InFocus students may accept, reject, or edit announcements for grammar, clarity, and unprotected speech.")
                    .font(.small)
            }
            .tint(Brand.fill)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.danger)
            }
            Button {
                Task { await send() }
            } label: {
                Label(sending ? "Submitting…" : "Submit announcement", systemImage: "megaphone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.brandPrimary)
            .disabled(sending || !draft.policyAgreed)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if !draft.policyAgreed {
                Text("Agree to the policy to submit.").font(.small).foregroundStyle(Brand.muted)
            }
        }
    }

    // MARK: Success

    private var success: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Announcement submitted").headline(.h3)
                    Spacer()
                    StatusTag(text: "Submitted", tone: .success)
                }
                Text("InFocus will review it for grammar, clarity, and unprotected speech. It will only run if accepted, and for at most \(AnnouncementForm.maxShowDays) consecutive show days.")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            Button("Submit another") {
                draft = AnnouncementForm.another(after: draft)
                submitted = false
                announcementFocused = true
            }
            .frame(minHeight: 44)
        } footer: {
            Text("Submit another keeps your details and dates.")
        }
    }

    // MARK: Helpers

    private var characterCountColor: Color {
        draft.announcement.trimmingCharacters(in: .whitespacesAndNewlines).count > AnnouncementForm.maxAnnouncementChars
            ? Brand.danger : Brand.muted
    }

    private var startBinding: Binding<Date> {
        Binding(get: { draft.startDate ?? Date() },
                set: { draft = AnnouncementForm.movingStart(draft, to: $0) })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { draft.endDate ?? draft.startDate ?? Date() }, set: { draft.endDate = $0 })
    }

    /// Signed in, the form starts with this person's email and name (they can change them).
    private func prefill() {
        guard !prefilled, let user = session.user, !user.sampleOnly else { return }
        prefilled = true
        if draft.email.isEmpty { draft.email = user.email }
        if draft.name.isEmpty { draft.name = user.name }
        if draft.startDate == nil { draft.startDate = Date() }
        if draft.endDate == nil { draft.endDate = draft.startDate }
    }

    private func send() async {
        guard !sending else { return }
        if draft.startDate == nil { draft.startDate = Date() }
        if draft.endDate == nil { draft.endDate = draft.startDate }
        error = nil
        guard let submission = AnnouncementForm.submission(draft) else {
            error = AnnouncementForm.problem(draft)
            return
        }
        sending = true
        defer { sending = false }
        do {
            _ = try await AnnouncementsAPI.current(client).submit(submission)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            submitted = true
        } catch {
            self.error = Loadable<AnnouncementReceipt>.message(for: error)
        }
    }
}
