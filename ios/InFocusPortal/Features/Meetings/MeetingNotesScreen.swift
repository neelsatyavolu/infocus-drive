import SwiftUI

/// Meetings → a meeting's notes, the native `/meetings/<id>`: the Scribe's summary,
/// the transcript from the Drive (loaded only when asked), when it really started and
/// ended, who's invited (hosts edit the list), and Join while it's live.
struct MeetingNotesScreen: View {
    let meetingId: String

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var state: Loadable<MeetingDetail> = .idle
    @State private var notAvailable = false
    @State private var transcript: String?
    @State private var loadingTranscript = false
    @State private var editingInvitees = false
    @State private var actionError: String?

    private var service: MeetingNotesService { MeetingNotesService(client: client) }

    var body: some View {
        Group {
            if notAvailable {
                ScrollView {
                    EmptyStateView(title: "Not available", message: "These notes are only for the people in this meeting.")
                }
            } else {
                LoadableView(state, retry: { Task { await load() } }) { meeting in
                    content(meeting)
                }
            }
        }
        .brandBackground()
        .navigationTitle("Meeting notes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if state.value?.canEditInvitees == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Invited") { editingInvitees = true }
                        .accessibilityLabel("Edit invited people")
                }
            }
        }
        .sheet(isPresented: $editingInvitees) {
            if let meeting = state.value {
                InviteesSheet(meeting: meeting, service: service) { Task { await load() } }
            }
        }
        .alert("Couldn't load the transcript", isPresented: Binding(get: { actionError != nil },
                                                                     set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
    }

    private func content(_ meeting: MeetingDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Nameplate(eyebrow: "Meeting notes", title: meeting.title,
                          subtitle: "\(MeetingDates.dayAndTime(meeting.startsAt)) · \(meeting.durationLabel) · \(meeting.participantCount) attended")
                tags(meeting)
                if meeting.isLive {
                    Button { router.joinMeeting(meeting.id) } label: { Label("Join", systemImage: "video.fill") }
                        .buttonStyle(.brandPrimary)
                        .accessibilityHint("Opens the meeting full screen")
                }
                summary(meeting)
                if meeting.hasTranscript { transcriptCard }
                details(meeting)
                if !meeting.invitees.isEmpty || meeting.canEditInvitees { invited(meeting) }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await load() }
    }

    private func tags(_ meeting: MeetingDetail) -> some View {
        HStack(spacing: 6) {
            if meeting.isLive { LiveTag() }
            if let access = meeting.accessLabel { StatusTag(text: access) }
            if meeting.notesStatus != "NONE" {
                StatusTag(text: meeting.notesStatus == "READY" ? "Notes ready"
                          : meeting.notesStatus == "FAILED" ? "Notes failed" : "Notes processing",
                          tone: meeting.notesStatus == "READY" ? .success : meeting.notesStatus == "FAILED" ? .danger : .neutral)
            }
        }
    }

    private func summary(_ meeting: MeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Summary")
            if let markdown = meeting.notesSummary, !markdown.isEmpty {
                NotesMarkdownView(markdown: markdown)
            } else {
                Text(meeting.notesMessage)
                    .font(.small)
                    .foregroundStyle(meeting.notesStatus == "FAILED" ? Brand.danger : Brand.secondary)
                if let reason = meeting.notesError {
                    Text("Reason: \(reason)").font(.small).foregroundStyle(Brand.secondary)
                }
            }
        }
        .card()
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Transcript")
            if let transcript {
                Text(verbatim: transcript) // plain, like the web
                    .font(.small)
                    .foregroundStyle(Brand.foreground)
                    .textSelection(.enabled)
            } else {
                Label("Stored on the InFocus Drive. Loaded only when you ask.", systemImage: "lock")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
                Button { Task { await loadTranscript() } } label: {
                    HStack {
                        if loadingTranscript { ProgressView() }
                        Text("Load transcript")
                    }
                }
                .buttonStyle(.brandSecondary)
                .disabled(loadingTranscript)
            }
        }
        .card()
    }

    private func details(_ meeting: MeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Details")
            LabeledContent("Started") {
                Text(meeting.startedAt.map(MeetingDates.clock) ?? "—").font(.mono(14))
            }
            LabeledContent("Ended") {
                Text(meeting.endedAt.map(MeetingDates.clock) ?? "—").font(.mono(14))
            }
            Text("Times are Pacific.").font(.small).foregroundStyle(Brand.muted)
        }
        .font(.bodyText)
        .card()
    }

    private func invited(_ meeting: MeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Invited · \(meeting.invitees.count)",
                          actionTitle: meeting.canEditInvitees ? "Edit" : nil,
                          action: meeting.canEditInvitees ? { editingInvitees = true } : nil)
            if meeting.invitees.isEmpty {
                Text(meeting.access == "OPEN" ? "No one picked, so every producer gets the start notification." : "No one picked yet.")
                    .font(.small).foregroundStyle(Brand.secondary)
            }
            ForEach(meeting.invitees) { person in
                Text(person.name).foregroundStyle(Brand.foreground)
            }
        }
        .card()
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await service.detail(meetingId))
            notAvailable = false
        } catch PortalError.forbidden, PortalError.sampleApp {
            notAvailable = true
        } catch {
            if state.value == nil { state = .failed(Loadable<MeetingDetail>.message(for: error)) }
        }
    }

    private func loadTranscript() async {
        loadingTranscript = true
        defer { loadingTranscript = false }
        do {
            transcript = try await service.transcript(meetingId)
        } catch {
            actionError = Loadable<String>.message(for: error)
        }
    }
}

/// The summary: headings, paragraphs and bullets with **bold**, as plain text (no links or HTML).
struct NotesMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(NotesMarkdown.parse(markdown).enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 8) {
                    if let heading = section.heading {
                        Text(heading).font(.h3).foregroundStyle(Brand.foreground).accessibilityAddTraits(.isHeader)
                    }
                    ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let text):
                            Text(NotesMarkdown.inline(text)).font(.bodyText).foregroundStyle(Brand.secondary)
                        case .list(let items):
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•").foregroundStyle(Brand.green).accessibilityHidden(true)
                                        Text(NotesMarkdown.inline(item)).font(.bodyText).foregroundStyle(Brand.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

/// Hosts pick who's invited. Invite-only meetings need at least one person.
private struct InviteesSheet: View {
    let meeting: MeetingDetail
    let service: MeetingNotesService
    let saved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var people: Loadable<[MeetingPerson]> = .idle
    @State private var selected: Set<String>
    @State private var query = ""
    @State private var saving = false
    @State private var error: String?

    init(meeting: MeetingDetail, service: MeetingNotesService, saved: @escaping () -> Void) {
        self.meeting = meeting
        self.service = service
        self.saved = saved
        _selected = State(initialValue: Set(meeting.invitees.map(\.id)))
    }

    private var inviteOnly: Bool { meeting.access == "INVITE_ONLY" }

    var body: some View {
        NavigationStack {
            LoadableView(people, retry: { Task { await load() } }) { people in
                List {
                    Section {
                        ForEach(filtered(people)) { person in
                            Button { toggle(person.id) } label: {
                                HStack {
                                    Text(person.name).foregroundStyle(Brand.foreground)
                                    Spacer()
                                    Image(systemName: selected.contains(person.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(person.id) ? Brand.green : Brand.control)
                                }
                                .frame(minHeight: 44)
                            }
                            .accessibilityAddTraits(selected.contains(person.id) ? .isSelected : [])
                        }
                    } footer: {
                        Text(inviteOnly ? "Only these producers (and you) can join this meeting."
                             : "These producers get the start notification. Leave empty to notify every producer.")
                    }
                    if let error {
                        Text(error).font(.small).foregroundStyle(Brand.danger)
                    }
                }
                .font(.bodyText)
                .scrollContentBackground(.hidden)
                .searchable(text: $query, prompt: "Name")
            }
            .brandBackground()
            .navigationTitle("Invited people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") { Task { await save() } }.disabled(people.value == nil)
                    }
                }
            }
            .task { await load() }
        }
    }

    private func filtered(_ people: [MeetingPerson]) -> [MeetingPerson] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? people : people.filter { $0.name.lowercased().contains(needle) }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func load() async {
        if people.value == nil { people = .loading }
        do {
            people = .loaded(try await service.people())
        } catch {
            people = .failed(Loadable<[MeetingPerson]>.message(for: error))
        }
    }

    private func save() async {
        if inviteOnly && selected.isEmpty { return error = "Choose at least one person." }
        saving = true
        defer { saving = false }
        do {
            try await service.setInvitees(meeting.id, userIds: Array(selected).sorted())
            saved()
            dismiss()
        } catch {
            self.error = Loadable<Int>.message(for: error)
        }
    }
}
