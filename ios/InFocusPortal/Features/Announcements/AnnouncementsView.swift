import SwiftUI

/// Class announcements, newest first: unread marked, like in place, open for comments.
/// Producers can post; the public submissions inbox stays on the Portal.
struct AnnouncementsView: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(BadgeCenter.self) private var badges
    @State private var composing = false
    private let feed = AnnouncementsStore.shared

    var body: some View {
        ScrollView {
            LoadableView(feed.state, retry: { Task { await feed.load(api: api, force: true) } }) { list in
                if list.isEmpty {
                    EmptyStateView(title: "No announcements yet", message: "Class announcements from producers show up here.")
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(list) { item in
                            NavigationLink(value: Route.announcements(.announcement(id: item.id))) {
                                AnnouncementCard(announcement: item, lineLimit: 6) {
                                    Task { await feed.toggleLike(item.id, api: api) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle("Announcements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { await feed.load(api: api, force: true) }
        .task { await feed.load(api: api) }
        .onChange(of: feed.unreadCount) { _, count in badges.set(count, for: .calendar) }
        .sheet(isPresented: $composing) { ComposeAnnouncementView() }
        .alert("Couldn't do that", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(feed.actionError ?? "")
        }
    }

    private var api: CalendarAPI { CalendarAPI.current(client) }

    private var errorShown: Binding<Bool> {
        Binding(get: { feed.actionError != nil }, set: { if !$0 { feed.actionError = nil } })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if session.user?.isProducer == true {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { composing = true } label: { Label("New announcement", systemImage: "square.and.pencil") }
                    Button {
                        router.openPortal("announcements/submitted", title: "Submitted")
                    } label: { Label("Submitted announcements", systemImage: "tray") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Announcement options")
            }
        }
    }
}

/// One announcement: author, when, text, mentions, likes and comment count.
struct AnnouncementCard: View {
    let announcement: ClassAnnouncement
    var lineLimit: Int?
    let onLike: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(announcement.author.name).font(.lexend(15, .semibold, relativeTo: .subheadline))
                Text(announcement.createdAt, format: .relative(presentation: .named))
                    .font(.small).foregroundStyle(Brand.muted)
                Spacer()
                if announcement.unread { StatusTag(text: "New", tone: .success) }
            }
            Text(announcement.content)
                .font(.bodyText)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !announcement.mentions.isEmpty {
                Text("With " + announcement.mentions.map(\.name).joined(separator: ", "))
                    .font(.small).foregroundStyle(Brand.green)
            }
            HStack(spacing: 20) {
                Button(action: onLike) {
                    Label("\(announcement.likeCount)", systemImage: announcement.likedByMe ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .frame(minHeight: 44)
                }
                .foregroundStyle(announcement.likedByMe ? Brand.green : Brand.secondary)
                .accessibilityLabel(announcement.likedByMe ? "Liked, \(announcement.likeCount) likes" : "Like, \(announcement.likeCount) likes")
                Label("\(announcement.comments.count)", systemImage: "bubble.left")
                    .foregroundStyle(Brand.secondary)
                    .accessibilityLabel("\(announcement.comments.count) comments")
                Spacer()
            }
            .font(.mono(14))
            .buttonStyle(.plain)
        }
        .card()
        .overlay(alignment: .leading) {
            if announcement.unread { Rectangle().fill(Brand.fill).frame(width: 4) }
        }
    }
}
