import SwiftUI

/// One #announcements post: avatar, author, time, text with tappable links, and attachments
/// (opened signed in through the Portal's Slack file proxy).
struct SlackPostCard: View {
    let post: SlackPost
    var unread = false
    var lineLimit: Int?

    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                SlackAvatar(name: post.authorName, imageURL: post.authorImageUrl)
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.authorName).font(.lexend(15, .semibold, relativeTo: .subheadline))
                    Text(post.timeLabel).font(.mono(12)).foregroundStyle(Brand.muted)
                }
                Spacer(minLength: 0)
                if unread { StatusTag(text: "New", tone: .success) }
            }
            .accessibilityElement(children: .combine)

            if !post.bodyParts.isEmpty {
                Text(SlackText.attributed(post.bodyParts))
                    .font(.bodyText)
                    .tint(Brand.green)
                    .lineLimit(lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            ForEach(post.attachments) { file in
                Button {
                    router.openPortal("api/slack/files/\(file.id)", title: file.title)
                } label: {
                    AttachmentRow(file: file)
                }
                .buttonStyle(.plain)
            }
        }
        .card()
        .overlay(alignment: .leading) {
            if unread { Rectangle().fill(Brand.fill).frame(width: 4) }
        }
    }
}

private struct AttachmentRow: View {
    let file: SlackPost.Attachment

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(Brand.muted)
            Text(file.title).font(.lexend(14, .medium, relativeTo: .subheadline)).lineLimit(1)
            Spacer(minLength: 8)
            if let type = file.prettyType, !type.isEmpty {
                Text(type.uppercased()).font(.lexend(11, .medium, relativeTo: .caption2)).tracking(1.2)
                    .foregroundStyle(Brand.muted)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
        .accessibilityLabel("Open attachment \(file.title)")
    }
}

/// The author's Slack photo, or initials on a neutral circle.
struct SlackAvatar: View {
    let name: String
    let imageURL: String?

    var body: some View {
        Group {
            if let imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initials
                }
            } else {
                initials
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: some View {
        Text(SlackText.initials(name))
            .font(.lexend(12, .bold))
            .foregroundStyle(Brand.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.raised)
    }
}

/// Text helpers shared by the feed views (pure, so they're unit tested).
enum SlackText {
    /// Plain runs and links as one attributed string; only http(s) links become tappable.
    static func attributed(_ parts: [SlackPost.Part]) -> AttributedString {
        var result = AttributedString()
        for part in parts {
            switch part {
            case .text(let value):
                result += AttributedString(value)
            case .link(let href, let label):
                var link = AttributedString(label.isEmpty ? href : label)
                if let url = URL(string: href), ["http", "https"].contains(url.scheme?.lowercased()) {
                    link.link = url
                    link.underlineStyle = .single
                }
                result += link
            }
        }
        return result
    }

    /// "Abby Example" → "AE"; "IF" when there's no name, as the web shows.
    static func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "IF" : letters.joined()
    }
}
