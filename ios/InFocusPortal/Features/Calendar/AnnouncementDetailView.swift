import SwiftUI

/// One announcement with its comments and a comment box. Opening it marks it read.
struct AnnouncementDetailView: View {
    let id: String

    @Environment(\.portalClient) private var client
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var composing: Bool
    private let feed = AnnouncementsStore.shared

    var body: some View {
        Group {
            if let item = feed.announcement(id) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        AnnouncementCard(announcement: item) { Task { await feed.toggleLike(id, api: api) } }
                        comments(item)
                    }
                    .padding(Brand.gutter)
                }
                .safeAreaInset(edge: .bottom) { composer }
            } else {
                LoadableView(feed.state, retry: { Task { await feed.load(api: api, force: true) } }) { _ in
                    EmptyStateView(title: "Announcement not found", message: "It may have been deleted.")
                }
            }
        }
        .brandBackground()
        .navigationTitle("Announcement")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await feed.load(api: api)
            await feed.markRead(id, api: api)
        }
        .alert("Couldn't do that", isPresented: Binding(get: { feed.actionError != nil },
                                                         set: { if !$0 { feed.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(feed.actionError ?? "")
        }
    }

    private var api: CalendarAPI { CalendarAPI.current(client) }

    @ViewBuilder
    private func comments(_ item: ClassAnnouncement) -> some View {
        SectionHeader(title: item.comments.isEmpty ? "No comments yet" : "Comments")
        ForEach(item.comments) { comment in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(comment.author.name).font(.lexend(14, .semibold, relativeTo: .subheadline))
                    Text(comment.createdAt, format: .relative(presentation: .named)).font(.small).foregroundStyle(Brand.muted)
                }
                Text(comment.body).font(.bodyText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Add a comment", text: $draft, axis: .vertical)
                .font(.bodyText)
                .lineLimit(1...5)
                .focused($composing)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(composing ? Brand.green : Brand.control))
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.onBrand)
                    .frame(width: 44, height: 44)
                    .background(canSend ? Brand.fill : Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
            }
            .disabled(!canSend)
            .accessibilityLabel("Send comment")
        }
        .padding(.horizontal, Brand.gutter)
        .padding(.vertical, 10)
        .background(Brand.background)
    }

    private var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true
        defer { sending = false }
        if await feed.addComment(body, to: id, api: api) {
            draft = ""
            composing = false
        }
    }
}
