import SwiftUI

/// The Class Board (`/class-board`): the cycle's race of packages, what's due next, livestreams and
/// the next two weeks of class days. iPhone stacks the sections; iPad puts the race on the left and
/// the rest in a column on the right, like the web board. The PIN lives in Settings → PINs.
struct ClassBoardScreen: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        if session.user?.sampleOnly == true {
            NotInSampleApp(title: "Class Board")
        } else {
            ClassBoardContent(isProducer: session.user?.isProducer == true)
        }
    }
}

private struct ClassBoardContent: View {
    let isProducer: Bool
    @Environment(\.portalClient) private var client
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model = ClassBoardModel()
    @State private var showingSettings = false

    private var api: CommunityAPI { CommunityAPI.current(client) }

    var body: some View {
        LoadableView(model.state, retry: { Task { await model.load(api: api) } }) { board in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ClassBoardHeader(board: board, stale: model.stale)
                    if sizeClass == .regular {
                        HStack(alignment: .top, spacing: 16) {
                            ClassBoardRace(board: board)
                            rail(board).frame(width: 360)
                        }
                    } else {
                        ClassBoardRace(board: board)
                        rail(board)
                    }
                }
                .padding(Brand.gutter)
            }
        }
        .brandBackground()
        .navigationTitle("Class Board")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isProducer {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Label("Board settings", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: { Task { await model.load(api: api) } }) {
            ClassBoardSettingsSheet()
        }
        .task {
            await model.load(api: api)
            await model.keepFresh(api: api)
        }
        .refreshable { await model.load(api: api) }
    }

    private func rail(_ board: ClassBoard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ClassBoardDueNext(deadlines: board.deadlines)
            ClassBoardLivestreams(items: board.livestreams)
            ClassBoardCalendar(days: board.days, today: ClassBoardFormat.dateKey(Date()))
        }
    }
}

/// The nameplate: Class Board with the package count, the cycle and its focus, today's date and
/// when the board last got data; then the class focus (Period 1) or the next step.
private struct ClassBoardHeader: View {
    let board: ClassBoard
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Nameplate(eyebrow: "Class Board · \(board.lanes.count) \(board.lanes.count == 1 ? "package" : "packages")",
                      title: "Cycle \(board.cycleNumber)",
                      subtitle: board.cycleFocus.isEmpty ? nil : board.cycleFocus) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(ClassBoardFormat.today(Date())).font(.small).foregroundStyle(Brand.secondary)
                    if stale {
                        StatusTag(text: "Not updated since \(ClassBoardFormat.time(board.generatedAt))", tone: .warning)
                    } else {
                        Text("Updated \(ClassBoardFormat.time(board.generatedAt))").font(.mono(12)).foregroundStyle(Brand.muted)
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let focus = ClassBoardFormat.focus(board, now: context.date) {
                    FocusCard(focus: focus)
                }
            }
        }
    }
}

private struct FocusCard: View {
    let focus: ClassBoardFormat.Focus

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(focus.eyebrow)
                Text(focus.text).headline(.h3).lineLimit(2)
                Text(focus.detail).font(.small).foregroundStyle(Brand.secondary)
            }
            Spacer(minLength: 0)
            if let countdown = focus.countdown {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(countdown).font(.mono(22, .medium)).foregroundStyle(focus.ending ? Brand.warning : Brand.foreground)
                    Text("Left in class").font(.small).foregroundStyle(Brand.muted)
                }
                .accessibilityElement(children: .combine)
            } else if let tag = focus.tag {
                StatusTag(text: tag, tone: focus.tone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}
