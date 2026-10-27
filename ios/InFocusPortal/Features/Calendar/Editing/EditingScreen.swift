import SwiftUI

/// Show > Editing (producers), like the Portal's `/editing`: pick a show, then start its automatic
/// edit from the recordings on Drive, follow it, watch the result, and approve it or send it back.
/// The editing machines, the editor's settings and the guide stay on the Portal (linked below).
struct EditingScreen: View {
    /// The show to open (`YYYY-MM-DD`); nil opens the next show.
    let date: String?

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var selected: String?
    @State private var overview: Loadable<ShowOverview> = .idle
    @State private var model: ShowEditModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Nameplate(eyebrow: "Editing", title: title, subtitle: "Automatic editing")
                LoadableView(state: overview, retry: { Task { await loadOverview() } }, placeholder: { SkeletonList(rows: 3) }) { show in
                    showPicker(show)
                    // A new identity per show, so instructions and picks don't carry over to another date.
                    if let model, model.date == show.date { EditingShowContent(model: model).id(model.date) }
                }
                portalLinks
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle("Editing")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            await loadOverview()
            await model?.load()
        }
        .task(id: selected ?? date) { await loadOverview() }
        .task(id: model?.date) {
            await model?.load()
            await model?.follow()
        }
    }

    private var title: String {
        if let date = overview.value?.date ?? selected ?? date { return CalendarDates.long(date) }
        return "Next show"
    }

    private func loadOverview() async {
        if overview.value == nil { overview = .loading }
        do {
            let show = try await CalendarEditAPI.current(client).showOverview(selected ?? date)
            overview = .loaded(show)
            if model?.date != show.date { model = ShowEditModel(date: show.date, api: .current(client)) }
        } catch {
            if overview.value == nil { overview = .failed(Loadable<ShowOverview>.message(for: error)) }
        }
    }

    @ViewBuilder
    private func showPicker(_ show: ShowOverview) -> some View {
        if show.upcomingShows.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(show.upcomingShows) { upcoming in
                        Chip(title: upcoming.label, selected: upcoming.date == show.date) { selected = upcoming.date }
                            .disabled(model?.busy != nil)
                    }
                }
            }
            .accessibilityLabel("Upcoming shows")
        }
    }

    /// Machines, Settings and How to open the Portal's own views.
    private var portalLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("On the Portal", color: Brand.muted)
            Text("Link and manage editing machines, change the editor's settings and house rules, or read the guide.")
                .font(.small).foregroundStyle(Brand.secondary)
            VStack(spacing: 8) {
                Button("Machines", systemImage: "desktopcomputer") { router.openPortal("editing?view=machines", title: "Machines") }
                Button("Settings", systemImage: "gearshape") { router.openPortal("editing?view=settings", title: "Editing settings") }
                Button("How to", systemImage: "book") { router.openPortal("editing?view=howto", title: "How to") }
            }
            .buttonStyle(.brandSecondary)
        }
        .card()
    }
}

/// Everything for one show's edit, under the show picker.
private struct EditingShowContent: View {
    let model: ShowEditModel

    var body: some View {
        switch model.state {
        case .idle, .loading:
            SkeletonList(rows: 3)
        case .failed(let message):
            EmptyStateView(title: "Couldn't load automatic editing", message: message, actionTitle: "Try again") {
                Task { await model.load() }
            }
        case .loaded(let state):
            loaded(state)
        }
    }

    @ViewBuilder
    private func loaded(_ state: ShowEditState) -> some View {
        let editor = ShowEditRules.editorStatus(state)
        StatusTag(text: editor.label, tone: editor.tone)
        if let error = model.error { EditErrorBanner(message: error) }
        if let notice = model.notice {
            Label(notice, systemImage: "checkmark.circle").font(.small).foregroundStyle(Brand.green)
        }
        EditStatusCard(model: model, state: state)
        if let job = state.job, job.status == "REVIEW" || (job.status == "PUBLISHED" && state.sentToYouTube) {
            EditReviewCard(model: model, state: state, job: job)
            let found = ShowEditRules.structure(job.decisions)
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("What the editor found", color: Brand.muted)
                    ForEach(Array(found.enumerated()), id: \.offset) { _, decision in
                        Text(decision.detail).font(.small).foregroundStyle(decision.flagged ? Brand.warning : Brand.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
        }
        if state.canStart { RecordingsCard(model: model, state: state) }
    }
}

/// "This show's edit": where it stands, Start (with instructions and a publish time), Cancel and Redo.
private struct EditStatusCard: View {
    let model: ShowEditModel
    let state: ShowEditState

    @Environment(Router.self) private var router
    @State private var instructions = false
    @State private var note = ""
    @State private var publishAt = Date()
    @State private var redoing = false
    @State private var redoNote = ""

    var body: some View {
        let summary = ShowEditRules.summary(state)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("This show's edit").headline(.h3)
                Spacer()
                StatusTag(text: summary.label, tone: summary.tone)
            }
            statusBody
            if let job = state.job, !state.canStart {
                if let note = job.note { EditNote(text: "Instructions: “\(note)”") }
                if let publishAt = job.publishAt {
                    EditNote(text: "Goes public: \(ShowEditRules.pacific(publishAt)) (picked with the instructions)")
                }
            }
            if state.canStart { startSection }
            if let job = state.job, ["FAILED", "REVIEW"].contains(job.status), !state.sentToYouTube { redo(job) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .onAppear { publishAt = ShowEditRules.usualPublishDate(showDate: model.date) }
    }

    @ViewBuilder
    private var statusBody: some View {
        if let job = state.job, job.isActive {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ShowEditRules.progress(job, waitingFor: state.waitingFor)).font(.bodyText)
            }
            .accessibilityElement(children: .combine)
            if !state.worker.online { EditNote(text: ShowEditRules.offlineNote) }
            Button(job.cancelRequested ? "Cancelling…" : job.pendingFix != nil ? "Cancel the fix" : "Cancel") {
                Task { await model.send(.cancel(id: job.id), success: "Cancelled.") }
            }
            .buttonStyle(QuietDestructiveButtonStyle())
            .disabled(model.busy != nil || job.cancelRequested)
        } else if state.job?.status == "FAILED" {
            Label(state.job?.error ?? "Unknown error.", systemImage: "exclamationmark.triangle")
                .font(.small).foregroundStyle(Brand.danger)
                .accessibilityLabel("The automatic edit failed: \(state.job?.error ?? "Unknown error.")")
        } else if state.job?.status == "PUBLISHED" || state.sentToYouTube {
            EditNote(text: ShowEditRules.sentLine(state.published))
            if let youtube = state.published?.youtubeUrl {
                Link(destination: youtube) { Label("Watch on YouTube", systemImage: "play.rectangle") }
                    .font(.small).foregroundStyle(Brand.green)
            }
        } else if state.job?.status == "CANCELLED" {
            EditNote(text: "The last automatic edit was cancelled. You can start it again.")
        } else if state.job?.status == "REVIEW" {
            EditNote(text: "The edit is done. Watch it below, then approve it or send it back.")
        } else {
            EditNote(text: "No automatic edit for this show yet.")
        }
    }

    private var startSection: some View {
        let selected = model.selected
        let problem = ShowEditRules.selectionError(selected)
        let used = selected.filter { $0.role != .ignore }
        let announcements = ShowEditRules.announcementNote(state.announcements)
        let packages = ShowEditRules.packageNote(state.packages)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await model.start(note: instructions ? note : "", publish: instructions ? publishAt : nil) }
            } label: {
                if model.busy == "start" { ProgressView() } else { Label("Start automatic editing", systemImage: "wand.and.stars") }
            }
            .buttonStyle(.brandPrimary)
            .disabled(model.busy != nil || problem != nil)
            Text(problem ?? "Uses \(used.count == 1 ? "1 recording" : "\(used.count) recordings"): \(used.map(\.fileName).joined(separator: ", ")). Change them under Recordings.")
                .font(.small).foregroundStyle(problem == nil ? Brand.muted : Brand.danger)
            Button(instructions ? "No instructions" : "Add instructions", systemImage: "text.bubble") { instructions.toggle() }
                .font(.small).foregroundStyle(Brand.green).frame(minHeight: 44)
            if instructions {
                NoteField(label: "Instructions for the editor (optional)",
                          placeholder: "e.g. Use the later take of the open, and leave out the yearbook announcement.",
                          text: $note, max: ShowEditRules.noteMax)
                EditNote(text: "For this show only. To make something permanent, add it to the house rules in Settings on the Portal.")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Goes public (Pacific)").font(.small).foregroundStyle(Brand.muted)
                    DatePicker("Goes public", selection: $publishAt).labelsHidden()
                        .environment(\.timeZone, ShowUploadRules.timeZone)
                    EditNote(text: ShowEditRules.publishSlot(publishAt, showDate: model.date) == nil
                             ? "The usual time. Change it only if this show goes public at another time."
                             : "This show goes public at this time instead of 8:30 AM on show day.")
                }
            }
            EditNote(text: announcements.text, warning: announcements.warning)
            if announcements.warning {
                Button("Open the script") { router.push(.calendar(.teleprompter(showDate: model.date, docId: nil))) }
                    .font(.small).foregroundStyle(Brand.green)
            }
            EditNote(text: packages.text, warning: packages.warning)
            if packages.warning {
                Button("Open the Publishing Queue") { router.push(.publishing(.home)) }
                    .font(.small).foregroundStyle(Brand.green)
            }
            if !state.worker.online { EditNote(text: ShowEditRules.offlineNote) }
        }
    }

    @ViewBuilder
    private func redo(_ job: ShowEditJob) -> some View {
        Button("Redo automatic edit", systemImage: "arrow.counterclockwise") { redoing.toggle() }
            .buttonStyle(.brandSecondary)
            .disabled(model.busy != nil)
        if redoing {
            NoteField(label: "Note for the editor (optional)",
                      placeholder: "What should it do differently? e.g. Use the later take of the close.",
                      text: $redoNote, max: ShowEditRules.noteMax)
            Button {
                Task {
                    let trimmed = redoNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    if await model.send(.redo(id: job.id, note: trimmed.isEmpty ? nil : trimmed), success: "Starting the edit over.") {
                        redoing = false
                        redoNote = ""
                    }
                }
            } label: {
                if model.busy == "redo" { ProgressView() } else { Text("Redo the edit") }
            }
            .buttonStyle(.brandSecondary)
            .disabled(model.busy != nil)
        }
    }
}

/// A quiet line of explanation; warnings carry an icon, never color alone.
struct EditNote: View {
    let text: String
    var warning = false

    var body: some View {
        if warning {
            Label(text, systemImage: "exclamationmark.triangle").font(.small).foregroundStyle(Brand.warning)
        } else {
            Text(text).font(.small).foregroundStyle(Brand.muted)
        }
    }
}

/// A labelled text box with a length limit (instructions, Redo notes, Send back).
struct NoteField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let max: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.small).foregroundStyle(Brand.muted)
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(3...8)
                .font(.bodyText)
                .padding(12)
                .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
                .onChange(of: text) { _, value in if value.count > max { text = String(value.prefix(max)) } }
                .accessibilityLabel(label)
        }
    }
}
