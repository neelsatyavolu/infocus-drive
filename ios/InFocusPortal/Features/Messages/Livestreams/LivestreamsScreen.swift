import SwiftUI

/// Livestreams (More → Livestreams): this semester's schedule, my sign-up requests, and for
/// managers the requests waiting on them.
struct LivestreamsScreen: View {
    enum Section: Hashable { case schedule, mine, review }

    @Environment(\.portalClient) private var client
    @State private var model: LivestreamsModel?
    @State private var section: Section = .schedule

    var body: some View {
        Group {
            if let model {
                LoadableView(model.state, retry: { Task { await model.load() } }) { schedule in
                    content(schedule, model: model)
                }
            } else {
                ScrollView { SkeletonList().padding(Brand.gutter) }
            }
        }
        .brandBackground()
        .navigationTitle("Livestreams")
        .navigationBarTitleDisplayMode(.inline)
        .livestreamAlerts(model)
        .task {
            let model = self.model ?? LivestreamsModel(service: .resolve(client))
            self.model = model
            await model.load()
        }
    }

    private func content(_ schedule: LivestreamSchedule, model: LivestreamsModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Nameplate(eyebrow: schedule.semester.label, title: "Livestreams",
                          subtitle: "Crew a game or event: \(Self.hours(schedule.requiredHours)) hours a semester.")
                Picker("Show", selection: $section) {
                    Text("Schedule").tag(Section.schedule)
                    Text("My requests").tag(Section.mine)
                    if schedule.canManage {
                        Text(schedule.pendingSignups.isEmpty ? "Review" : "Review (\(schedule.pendingSignups.count))")
                            .tag(Section.review)
                    }
                }
                .pickerStyle(.segmented)

                switch section {
                case .schedule: ScheduleList(schedule: schedule)
                case .mine: MyRequestsList(schedule: schedule)
                case .review: ReviewQueue(schedule: schedule, model: model)
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.load() }
    }

    static func hours(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

private struct ScheduleList: View {
    let schedule: LivestreamSchedule

    var body: some View {
        let split = LivestreamsModel.split(schedule.events)
        VStack(alignment: .leading, spacing: 10) {
            if schedule.events.isEmpty {
                EmptyStateView(title: "Nothing scheduled yet",
                               message: "Livestreams for this semester show up here as producers add them.")
            }
            if !split.upcoming.isEmpty {
                SectionHeader(title: "Coming up")
                ForEach(split.upcoming) { EventRow(event: $0, schedule: schedule) }
            }
            if !split.earlier.isEmpty {
                SectionHeader(title: "Earlier this semester").padding(.top, 8)
                ForEach(split.earlier) { EventRow(event: $0, schedule: schedule) }
            }
        }
    }
}

private struct EventRow: View {
    let event: LivestreamEvent
    let schedule: LivestreamSchedule

    var body: some View {
        NavigationLink(value: Route.messages(.livestream(id: event.id))) {
            HStack(alignment: .top, spacing: 12) {
                EventDateBlock(date: event.startsAt)
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.lexend(16, .semibold, relativeTo: .headline))
                        .foregroundStyle(Brand.foreground)
                        .multilineTextAlignment(.leading)
                    Text([FeatureDates.clock(event.startsAt), event.location].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.small)
                        .foregroundStyle(Brand.secondary)
                    LivestreamTags(event: event, schedule: schedule)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Brand.muted).padding(.top, 4)
            }
            .card(padding: 12)
            .opacity(event.status == .cancelled ? 0.6 : 1)
        }
        .buttonStyle(.plain)
    }
}

private struct MyRequestsList: View {
    let schedule: LivestreamSchedule

    var body: some View {
        let requests = schedule.mySignups.sorted { $0.createdAt > $1.createdAt }
        VStack(alignment: .leading, spacing: 10) {
            if requests.isEmpty {
                EmptyStateView(title: "No requests yet",
                               message: "Open a livestream on the schedule and request to crew it.")
            }
            ForEach(requests) { request in
                let event = schedule.event(request.eventId)
                NavigationLink(value: Route.messages(.livestream(id: request.eventId))) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(event?.title ?? "Livestream").font(.lexend(16, .semibold, relativeTo: .headline))
                            Spacer()
                            StatusTag(text: SignupStatusText.word(request.status), tone: SignupStatusText.tone(request.status))
                        }
                        if let event { Text(FeatureDates.dayAndTime(event.startsAt)).font(.small).foregroundStyle(Brand.secondary) }
                        if let note = request.note, !note.isEmpty {
                            Text("“\(note)”").font(.small).foregroundStyle(Brand.muted)
                        }
                    }
                    .card(padding: 12)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

enum SignupStatusText {
    static func word(_ status: SignupStatus) -> String {
        switch status {
        case .pending: "Pending"
        case .approved: "Approved"
        case .denied: "Denied"
        }
    }

    static func tone(_ status: SignupStatus) -> StatusTag.Tone {
        switch status {
        case .pending: .warning
        case .approved: .success
        case .denied: .danger
        }
    }
}
