import SwiftUI

/// #announcements from Slack, newest first, grouped by day (as `/announcements` shows it).
/// Posting happens in Slack; producers get Submitted and PA from the toolbar.
struct AnnouncementsView: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @Environment(BadgeCenter.self) private var badges
    private let feed = AnnouncementsStore.shared
    @State private var unreadAtOpen: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Nameplate(eyebrow: "Slack", title: "Announcements", subtitle: "Posts from #announcements.")
                LoadableView(feed.state, retry: { Task { await feed.load(api: api, force: true) } }) { channel in
                    content(channel)
                }
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle("Announcements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { await feed.load(api: api, force: true) }
        .task {
            await feed.load(api: api)
            unreadAtOpen = Set(feed.posts.filter(feed.isUnread).map(\.id))
            feed.markAllSeen()
            badges.set(feed.unreadCount, for: .calendar)
        }
    }

    private var api: AnnouncementsAPI { AnnouncementsAPI.current(client) }

    @ViewBuilder
    private func content(_ channel: SlackFeed) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = channel.error {
                MessageBanner(text: error)
            }
            if !channel.configured {
                EmptyStateView(title: "Slack isn't connected", message: "Slack announcements are not connected yet.")
            } else if channel.items.isEmpty {
                EmptyStateView(title: "No announcements yet", message: "Posts in #announcements show up here.")
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(AnnouncementDays.group(channel.items), id: \.label) { day in
                        Eyebrow(day.label, color: Brand.muted)
                            .padding(.top, 8)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(day.posts) { post in
                            NavigationLink(value: Route.announcements(.announcement(id: post.id))) {
                                SlackPostCard(post: post, unread: unreadAtOpen.contains(post.id), lineLimit: 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if session.user?.isProducer == true {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    NavigationLink(value: Route.announcements(.submitted)) {
                        Label("Submitted announcements", systemImage: "tray.full")
                    }
                    NavigationLink(value: Route.announcements(.pa)) {
                        Label("PA script", systemImage: "mic")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Announcement tools")
            }
        }
    }
}

/// Posts grouped under their day label, in feed order (the Portal sends newest first).
enum AnnouncementDays {
    struct Day: Equatable {
        let label: String
        var posts: [SlackPost]
    }

    static func group(_ posts: [SlackPost]) -> [Day] {
        var days: [Day] = []
        for post in posts {
            if days.last?.label == post.dateLabel {
                days[days.count - 1].posts.append(post)
            } else {
                days.append(Day(label: post.dateLabel, posts: [post]))
            }
        }
        return days
    }
}

/// A warning-tinted line for a problem the screen can still work around.
struct MessageBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.small)
            .foregroundStyle(Brand.warning)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.warningTint, in: RoundedRectangle(cornerRadius: Brand.radius))
    }
}
