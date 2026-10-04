import SwiftUI

/// More → Meetings (producers): the live meeting with a big Join, upcoming meetings
/// by Pacific day, and past meetings (their notes open in the Portal page).
struct MeetingsScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var model: MeetingsModel?

    var body: some View {
        Group {
            if let model {
                LoadableView(model.state, retry: { Task { await model.load() } }) { list in
                    content(list, model: model)
                }
            } else {
                ScrollView { SkeletonList().padding(Brand.gutter) }
            }
        }
        .brandBackground()
        .navigationTitle("Meetings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let model = self.model ?? MeetingsModel(service: .resolve(client))
            self.model = model
            await model.load()
        }
    }

    private func content(_ list: MeetingsList, model: MeetingsModel) -> some View {
        ScrollView {
            // Re-evaluates Join windows while the screen is open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 16) {
                    if list.live.isEmpty && list.upcoming.isEmpty {
                        EmptyStateView(title: "No meetings coming up",
                                       message: "Producer meetings and ones you're invited to show up here.")
                    }
                    ForEach(list.live) { meeting in
                        LiveMeetingCard(meeting: meeting) { router.joinMeeting(meeting.id) }
                    }
                    ForEach(MeetingDates.groupByDay(list.upcoming, now: context.date)) { day in
                        SectionHeader(title: day.heading).padding(.top, 4)
                        ForEach(day.meetings) { meeting in
                            UpcomingMeetingRow(meeting: meeting, now: context.date) { router.joinMeeting(meeting.id) }
                        }
                    }
                    if !list.past.isEmpty {
                        SectionHeader(title: "Past meetings").padding(.top, 8)
                        ForEach(list.past) { meeting in
                            PastMeetingRow(meeting: meeting) {
                                router.openPortal("meetings/\(meeting.id)", title: meeting.title)
                            }
                        }
                    }
                }
                .padding(Brand.gutter)
            }
        }
        .refreshable { await model.load() }
    }
}

/// "Live now": the meeting that's on, with one primary Join.
private struct LiveMeetingCard: View {
    let meeting: MeetingSummary
    let join: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LiveTag(label: "Live now")
                if meeting.isInviteOnly { InviteOnlyMark() }
                Spacer()
            }
            Text(meeting.title).headline(.h2).fixedSize(horizontal: false, vertical: true)
            Text("Started \(MeetingDates.clock(meeting.startsAt))")
                .font(.small)
                .foregroundStyle(Brand.secondary)
            Button(action: join) {
                Label("Join", systemImage: "video.fill")
            }
            .buttonStyle(.brandPrimary)
            .accessibilityHint("Opens the meeting full screen")
        }
        .card()
    }
}

private struct UpcomingMeetingRow: View {
    let meeting: MeetingSummary
    let now: Date
    let join: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(meeting.title).font(.h3).foregroundStyle(Brand.foreground)
                    if meeting.isInviteOnly { InviteOnlyMark() }
                }
                Text("\(MeetingDates.clock(meeting.startsAt)) · \(meeting.durationMinutes) min")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
            }
            Spacer(minLength: 8)
            joinControl
        }
        .card(padding: 14)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var joinControl: some View {
        switch meeting.joinState(now: now) {
        case .open:
            Button("Join", action: join)
                .buttonStyle(.brandPrimary)
                .fixedSize()
        case .opensAt(let date):
            Text("Opens at \(MeetingDates.clock(date))")
                .font(.small)
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.trailing)
        case .closed:
            EmptyView()
        }
    }
}

private struct PastMeetingRow: View {
    let meeting: MeetingSummary
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title).font(.h3).foregroundStyle(Brand.foreground)
                    Text(MeetingDates.dayAndTime(meeting.startsAt)).font(.small).foregroundStyle(Brand.secondary)
                }
                Spacer(minLength: 8)
                if let notes = meeting.notesLabel {
                    StatusTag(text: notes, tone: meeting.notesStatus == "READY" ? .success
                              : meeting.notesStatus == "FAILED" ? .danger : .neutral)
                }
                Image(systemName: "chevron.right").font(.small).foregroundStyle(Brand.muted)
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the meeting's notes")
    }
}

/// Lock icon plus a spoken label (status never by color or icon alone).
private struct InviteOnlyMark: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.lexend(12, .medium))
            .foregroundStyle(Brand.muted)
            .accessibilityLabel("Invite only")
    }
}
