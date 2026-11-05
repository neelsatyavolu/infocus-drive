import SwiftUI

/// The Thanksgiving leaderboard (`/thanksgiving`, `GET api/thanksgiving`): the contest, then
/// everyone's catches this November, ties sharing a rank, the viewer's row marked, and
/// disqualified accounts under the ranks. The exec review list stays on the web.
struct LeaderboardScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<HarvestBoard> = .idle

    var body: some View {
        Group {
            if session.user?.sampleOnly == true {
                EmptyStateView(title: "Not in the sample app", message: "The class leaderboard is on the InFocus Portal.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LoadableView(state, retry: { Task { await load() } }) { board in
                        LeaderboardContent(board: board)
                    }
                    .padding(Brand.gutter)
                }
                .refreshable { await load() }
                .task { if state.value == nil { await load() } }
            }
        }
        .brandBackground()
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await HarvestAPI.current(client).board())
        } catch {
            // Keep a board already on screen when a refresh fails.
            if state.value == nil { state = .failed(Loadable<HarvestBoard>.message(for: error)) }
        }
    }
}

private struct LeaderboardContent: View {
    let board: HarvestBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Thanksgiving \(String(board.year))")
                Text("Catch leaves, eat pies, snap wishbones, spot the giant turkey and pardon the ones that strut by (five taps each). Every catch counts one.")
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let contest = board.contest, board.year == Calendar.current.component(.year, from: contest.closesAt) {
                ContestBanner(text: ContestBannerText(contest: contest, viewerId: board.viewerId))
            }
            if board.viewerDisqualified {
                DisqualifiedNotice()
            }
            if board.isEmpty {
                EmptyStateView(title: "Nobody's on the board yet", message: "Catch a falling leaf or eat a pie on Home and you're first.")
                    .card()
            } else {
                VStack(spacing: 0) {
                    ForEach(board.rows) { entry in
                        BoardRow(entry: entry, isViewer: board.isViewer(entry), disqualified: false)
                        Divider().overlay(Brand.line)
                    }
                    ForEach(board.disqualified) { entry in
                        BoardRow(entry: entry, isViewer: board.isViewer(entry), disqualified: true)
                        Divider().overlay(Brand.line)
                    }
                }
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.line))
                .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
            }
        }
    }
}

/// The contest in big letters (components/thanksgiving/contest-banner.tsx).
private struct ContestBanner: View {
    let text: ContestBannerText

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text.headline)
                .font(.lexend(28, .semibold, relativeTo: .largeTitle))
                .tracking(-0.5)
                .foregroundStyle(Brand.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text(text.detail)
                .font(.small)
                .foregroundStyle(Brand.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Brand.greenTint, in: RoundedRectangle(cornerRadius: Brand.radius))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.green))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Leaderboard contest. \(text.headline). \(text.detail)")
    }
}

private struct DisqualifiedNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("You're disqualified for now", systemImage: "exclamationmark.triangle")
                .font(.lexend(15, .semibold))
                .foregroundStyle(Brand.warning)
            Text("Some of your catches looked automated, so you can't place or win while an exec checks them. You can keep playing; if it's all you, they'll restore you with everything you caught.")
                .font(.small)
                .foregroundStyle(Brand.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.warningTint, in: RoundedRectangle(cornerRadius: Brand.radius))
    }
}

/// Rank, name and total on top; each kind's count underneath with the web's labels.
private struct BoardRow: View {
    let entry: HarvestEntry
    let isViewer: Bool
    let disqualified: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(disqualified ? "–" : "\(entry.rank ?? 0)")
                .font(.mono(15, .medium, relativeTo: .body))
                .monospacedDigit()
                .foregroundStyle(Brand.muted)
                .frame(minWidth: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.lexend(16, .medium))
                        .foregroundStyle(disqualified ? Brand.muted : Brand.foreground)
                        .lineLimit(1)
                    if isViewer {
                        Text("You").font(.small).foregroundStyle(Brand.muted)
                    }
                    if disqualified { StatusTag(text: "Disqualified", tone: .danger) }
                    Spacer(minLength: 8)
                    Text("\(entry.total)")
                        .font(.mono(17, .semibold, relativeTo: .body))
                        .monospacedDigit()
                        .strikethrough(disqualified)
                        .foregroundStyle(disqualified ? Brand.muted : Brand.foreground)
                }
                KindCounts(entry: entry, struck: disqualified)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isViewer && !disqualified ? Brand.greenTint : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let place = disqualified ? "Not ranked, disqualified" : "Rank \(entry.rank ?? 0)"
        let kinds = HarvestKind.allCases.map { "\($0.label) \(entry.count($0))" }.joined(separator: ", ")
        return "\(place). \(entry.name)\(isViewer ? ", you" : ""). Total \(entry.total). \(kinds)"
    }
}

private struct KindCounts: View {
    let entry: HarvestEntry
    let struck: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { items }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 4) { items }
        }
    }

    @ViewBuilder private var items: some View {
        ForEach(HarvestKind.allCases, id: \.self) { kind in
            HStack(spacing: 4) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.green)
                Text(kind.label).font(.lexend(12)).foregroundStyle(Brand.muted)
                Text("\(entry.count(kind))")
                    .font(.mono(12, .medium))
                    .monospacedDigit()
                    .strikethrough(struck)
                    .foregroundStyle(Brand.secondary)
            }
            .fixedSize()
        }
    }
}
