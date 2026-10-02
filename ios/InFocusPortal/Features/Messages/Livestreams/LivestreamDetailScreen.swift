import SwiftUI

/// One livestream: when and where, crew, notes, and the sign-up request.
struct LivestreamDetailScreen: View {
    let eventId: String
    @Environment(\.portalClient) private var client
    @State private var model: LivestreamsModel?

    var body: some View {
        Group {
            if let model {
                LoadableView(model.state, retry: { Task { await model.load() } }) { schedule in
                    if let event = schedule.event(eventId) {
                        LivestreamDetail(event: event, schedule: schedule, model: model)
                    } else {
                        EmptyStateView(title: "Not on this semester's schedule",
                                       message: "This livestream was removed or belongs to another semester.")
                    }
                }
            } else {
                ScrollView { SkeletonList(rows: 3).padding(Brand.gutter) }
            }
        }
        .brandBackground()
        .navigationTitle("Livestream")
        .navigationBarTitleDisplayMode(.inline)
        .livestreamAlerts(model)
        .task {
            let model = self.model ?? LivestreamsModel(service: .resolve(client))
            self.model = model
            await model.load()
        }
    }
}

private struct LivestreamDetail: View {
    let event: LivestreamEvent
    let schedule: LivestreamSchedule
    let model: LivestreamsModel
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Nameplate(eyebrow: LivestreamTags.availability(event.availability), title: event.title,
                          subtitle: FeatureDates.dayAndTime(event.startsAt))
                LivestreamTags(event: event, schedule: schedule)
                facts
                crew
                if !event.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title: "Notes")
                        Text(event.notes).font(.bodyText).foregroundStyle(Brand.secondary).textSelection(.enabled)
                    }
                }
                signup
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.load() }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            fact("mappin.and.ellipse", "Where", event.location.isEmpty ? "To be announced" : event.location)
            fact("clock", "Arrive", FeatureDates.dayAndTime(event.startsAt))
            if let hours = event.hours {
                fact("hourglass", "Credit", "\(LivestreamsScreen.hours(hours)) hours")
            }
            if let manager = event.manager?.name {
                fact("person.crop.circle.badge.checkmark", "Manager", manager)
            }
        }
        .card()
    }

    private func fact(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Brand.green).frame(width: 20).accessibilityHidden(true)
            Text(label).font(.small).foregroundStyle(Brand.muted).frame(width: 64, alignment: .leading)
            Text(value).font(.bodyText).foregroundStyle(Brand.foreground)
        }
        .accessibilityElement(children: .combine)
    }

    private var crew: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Crew")
                Text("\(event.attendeeCount)/\(event.capacity)").font(.mono(13, .medium)).foregroundStyle(Brand.secondary)
                    .accessibilityLabel("\(event.attendeeCount) of \(event.capacity) spots filled")
            }
            if event.attendees.isEmpty {
                Text("Nobody yet.").font(.small).foregroundStyle(Brand.muted)
            } else {
                FlowRow(names: event.attendees.map(\.firstName))
            }
        }
    }

    @ViewBuilder
    private var signup: some View {
        switch SignupAction.for(event, schedule: schedule) {
        case .onCrew:
            notice("checkmark.seal", "You're on the crew for this livestream.", tone: .success)
        case .pending:
            notice("hourglass", "Your request is waiting for a livestream manager.", tone: .warning)
        case .full:
            notice("person.3", "The crew is full.", tone: .neutral)
        case .closed(let why):
            notice("xmark.circle", "\(why). Sign-ups are closed.", tone: .neutral)
        case .managerCannotSignUp:
            notice("info.circle", "Livestream managers run the crew instead of signing up.", tone: .neutral)
        case .request(let again):
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: again ? "Your last request was denied" : "Crew this livestream")
                TextField("Optional note (e.g. leaving at halftime)", text: $note, axis: .vertical)
                    .font(.bodyText)
                    .lineLimit(1...4)
                    .padding(12)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                    .onChange(of: note) { _, value in if value.count > 500 { note = String(value.prefix(500)) } }
                Button(again ? "Request again" : "Request sign-up") {
                    Task { if await model.requestSignup(event, note: note) { note = "" } }
                }
                .buttonStyle(.brandPrimary)
                .disabled(model.busy != nil)
            }
        }
    }

    private func notice(_ icon: String, _ text: String, tone: StatusTag.Tone) -> some View {
        Label(text, systemImage: icon)
            .font(.bodyText)
            .foregroundStyle(tone == .success ? Brand.green : tone == .warning ? Brand.warning : Brand.secondary)
            .card()
    }
}

/// Crew first names as wrapping chips.
private struct FlowRow: View {
    let names: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(.lexend(14, .medium, relativeTo: .subheadline))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
            }
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
