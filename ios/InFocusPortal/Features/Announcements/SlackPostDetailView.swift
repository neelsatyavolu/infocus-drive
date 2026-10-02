import SwiftUI

/// One #announcements post in full, with Open in Slack and Share.
struct SlackPostDetailView: View {
    let id: String

    @Environment(\.portalClient) private var client
    @Environment(\.openURL) private var openURL
    private let feed = AnnouncementsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let post = feed.post(id) {
                    Eyebrow(post.dateLabel, color: Brand.muted)
                    SlackPostCard(post: post)
                    actions(post)
                } else {
                    LoadableView(feed.state, retry: { Task { await feed.load(api: api, force: true) } }) { _ in
                        EmptyStateView(title: "Post not found", message: "It may have been deleted in Slack.")
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle("Announcement")
        .navigationBarTitleDisplayMode(.inline)
        .task { await feed.load(api: api) }
    }

    private var api: AnnouncementsAPI { AnnouncementsAPI.current(client) }

    @ViewBuilder
    private func actions(_ post: SlackPost) -> some View {
        if let url = URL(string: post.permalink) {
            HStack(spacing: 12) {
                Button { openURL(url) } label: {
                    Label("Open in Slack", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.brandSecondary)
                ShareLink(item: post.text.isEmpty ? post.permalink : post.text) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.brandSecondary)
            }
        }
    }
}
