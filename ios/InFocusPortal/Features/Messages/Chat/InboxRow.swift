import SwiftUI

/// One chat in the inbox: avatar, title, package subtitle, last message, time, unread count.
struct InboxRow: View {
    let chat: ChatSummary
    var isOpening = false
    /// A direct chat with someone this person blocked.
    var blocked = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: chat.title, isGroup: chat.kind == .group)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title)
                        .font(.lexend(16, chat.unreadCount > 0 ? .semibold : .medium, relativeTo: .body))
                        .foregroundStyle(Brand.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let updatedAt = chat.updatedAt {
                        Text(FeatureDates.inbox(updatedAt))
                            .font(.small)
                            .foregroundStyle(chat.unreadCount > 0 ? Brand.green : Brand.muted)
                    }
                }
                Text(chat.subtitle)
                    .font(.lexend(12, .medium, relativeTo: .caption))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(1)
                HStack(alignment: .top) {
                    Text(blocked ? "Blocked" : chat.preview ?? "No messages yet")
                        .font(.small)
                        .foregroundStyle(blocked || chat.preview == nil ? Brand.muted : Brand.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if isOpening {
                        ProgressView().controlSize(.small)
                    } else if chat.unreadCount > 0 {
                        UnreadCount(count: chat.unreadCount)
                    }
                }
            }
        }
        .padding(12)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [chat.title, chat.subtitle]
        if chat.unreadCount > 0 { parts.append("\(chat.unreadCount) unread") }
        if blocked {
            parts.append("Blocked")
        } else if let preview = chat.preview {
            parts.append(preview)
        }
        if let updatedAt = chat.updatedAt { parts.append(FeatureDates.inbox(updatedAt)) }
        return parts.joined(separator: ", ")
    }
}

/// Unread count: InFocus Green with Soft White, label style.
struct UnreadCount: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.mono(12, .medium))
            .foregroundStyle(Brand.onBrand)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(Brand.fill, in: RoundedRectangle(cornerRadius: Brand.tagRadius))
    }
}
