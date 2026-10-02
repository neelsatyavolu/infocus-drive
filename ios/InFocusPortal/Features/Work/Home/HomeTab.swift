import SwiftUI

/// Home: a greeting, what's due next, the member's package this cycle, the
/// grade snapshot (students), quick actions and recent activity. The App
/// Review sample account sees its sample workspace's projects instead.
struct HomeTab: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<HomePayload> = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                greeting
                LoadableView(state, retry: { Task { await load() } }) { home in
                    if session.user?.sampleOnly == true {
                        SampleProjectsSection(workspaces: home.workspaces)
                    } else {
                        content(home)
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await load() }
        .brandBackground()
        .navigationTitle("Home")
        .task { if state.value == nil { await load() } }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            Text(session.user?.sampleOnly == true ? "Welcome" : "Hi, \(session.user?.displayName ?? "there")")
                .headline(.h1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func content(_ home: HomePayload) -> some View {
        if let upNext = home.upNext {
            DueNextCard(upNext: upNext) { stage in
                router.select(.work)
                router.push(.work(.studentStage(stage)), on: .work)
            }
            PackageCard(upNext: upNext)
        } else if session.user?.doesStudentWork == true {
            EmptyStateView(title: "No package yet", message: "When you're on a Package Cycle roster, your package shows up here.")
                .card()
        }
        if let snapshot = home.snapshot {
            SnapshotCard(snapshot: snapshot) {
                router.select(.more)
                router.push(.grades(.grades), on: .more)
            }
        }
        QuickActions()
        if !home.activity.isEmpty {
            ActivitySection(entries: home.activity)
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await workAPI(client).home())
        } catch {
            if state.value == nil { state = .failed(Loadable<HomePayload>.message(for: error)) }
        }
    }
}

/// The next check-in with a live countdown (deadlines close 11:59 PM Pacific).
private struct DueNextCard: View {
    let upNext: UpNext
    let open: (StudentStage) -> Void

    var body: some View {
        if let next = upNext.nextStage {
            Button { if let stage = next.studentStage { open(stage) } } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Due next")
                    HStack(alignment: .firstTextBaseline) {
                        Text(next.label).headline(.h2)
                        Spacer()
                        countdown(next)
                    }
                    if let close = next.closesAt {
                        Text("Closes \(close.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))")
                            .font(.small)
                            .foregroundStyle(Brand.secondary)
                    }
                }
                .card()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(next.label)")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Cycle \(upNext.cycleNumber)")
                Text("Every check-in is done").headline(.h3)
                Text("Nice work. Your Final Cut is in.").font(.small).foregroundStyle(Brand.secondary)
            }
            .card()
        }
    }

    private func countdown(_ stage: DueStage) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let close = stage.closesAt, let left = Deadline.remaining(until: close, now: context.date) {
                Text(left)
                    .font(.mono(17, .medium))
                    .monospacedDigit()
                    .foregroundStyle(close.timeIntervalSince(context.date) < 86_400 ? Brand.warning : Brand.green)
                    .accessibilityLabel("\(left) left")
            } else if stage.closesAt != nil {
                StatusTag(text: "Past due", tone: .danger)
            }
        }
    }
}

/// The member's package this cycle: topic, group, producer and check-in progress.
private struct PackageCard: View {
    let upNext: UpNext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Nameplate(eyebrow: "Cycle \(upNext.cycleNumber) package",
                      title: upNext.groupTopic ?? "Untitled package",
                      subtitle: upNext.memberNames.isEmpty ? nil : upNext.memberNames.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if let producer = upNext.producerName {
                        Label("Producer: \(producer)", systemImage: "person.crop.circle")
                            .font(.small)
                            .foregroundStyle(Brand.secondary)
                    }
                    Spacer()
                    Text("\(upNext.checkInsDone)/\(upNext.checkInsTotal)")
                        .font(.mono(14, .medium))
                        .foregroundStyle(Brand.foreground)
                        .accessibilityLabel("\(upNext.checkInsDone) of \(upNext.checkInsTotal) check-ins done")
                }
                ProgressView(value: Double(upNext.checkInsDone), total: Double(max(upNext.checkInsTotal, 1)))
                    .tint(Brand.fill)
                ForEach(upNext.stages) { stage in
                    HStack(spacing: 10) {
                        Image(systemName: stage.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(stage.done ? Brand.green : Brand.muted)
                            .accessibilityHidden(true)
                        Text(stage.label).font(.bodyText).foregroundStyle(Brand.foreground)
                        Spacer()
                        if let close = stage.closesAt {
                            Text(close.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.mono(13))
                                .foregroundStyle(Brand.muted)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(stage.done ? "Done" : "Not done")
                }
            }
            .padding(16)
            .background(Brand.card)
        }
        .overlay(Rectangle().strokeBorder(Brand.line))
    }
}
