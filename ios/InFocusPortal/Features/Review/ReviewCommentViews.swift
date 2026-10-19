import SwiftUI

/// The comment box: at the playhead (video), at a pin (image), or a general note.
struct ReviewComposer: View {
    let isImage: Bool
    let currentTime: Double
    @Binding var draftPin: CGPoint?
    let busy: Bool
    let post: (_ body: String, _ atTime: Bool) async -> Bool
    @State private var text = ""
    @State private var atTime = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if isImage {
                    if draftPin != nil {
                        StatusTag(text: "Pinned", tone: .success)
                        Button("Remove pin") { draftPin = nil }.font(.small).foregroundStyle(Brand.green).frame(minHeight: 44)
                    } else {
                        Text("Tap the image to pin your comment, or leave a general one.").font(.small).foregroundStyle(Brand.muted)
                    }
                } else {
                    Toggle(isOn: $atTime) {
                        Text("At \(ReviewLogic.timecode(currentTime))").font(.mono(13, .medium)).monospacedDigit()
                    }
                    .toggleStyle(.button)
                    .tint(Brand.green)
                    .accessibilityHint("When on, the comment is pinned to this moment in the video")
                }
                Spacer(minLength: 0)
            }
            TextField("Add a comment", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .font(.bodyText)
                .focused($focused)
                .padding(10)
                .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
            Button {
                Task {
                    if await post(text, atTime) {
                        text = ""
                        focused = false
                    }
                }
            } label: {
                if busy { ProgressView().tint(Brand.onBrand) } else { Text("Comment") }
            }
            .buttonStyle(.brandPrimary)
            .disabled(busy || ReviewLogic.cleanComment(text) == nil)
        }
        .card()
    }
}

/// A comment with its replies and what this person may do with it.
struct ReviewThreadView: View {
    let thread: ReviewLogic.Thread
    let number: Int
    let selected: Bool
    /// Videos: pins carry a moment too, so show their timecode.
    var showsTime = false
    var canReply = true
    let canResolve: Bool
    let canDelete: (ReviewComment) -> Bool
    let canEdit: (ReviewComment) -> Bool
    let onSelect: () -> Void
    let onReply: (String) async -> Bool
    let onResolve: () -> Void
    let onEdit: (ReviewComment) -> Void
    let onDelete: (ReviewComment) -> Void
    @State private var replying = false
    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    header(thread.root)
                    Text(thread.root.body).font(.bodyText).foregroundStyle(Brand.foreground).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsTime && thread.root.targetType != .general ? "Plays the video from this moment" : "")
            ForEach(thread.replies) { reply in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(reply.authorName ?? "Reviewer").font(.lexend(13, .semibold))
                        Text(reply.createdAt, format: .relative(presentation: .named)).font(.small).foregroundStyle(Brand.muted)
                        Spacer()
                        actions(for: reply)
                    }
                    Text(reply.body).font(.lexend(15))
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Brand.line).frame(width: 2) }
            }
            HStack(spacing: 16) {
                if canReply { Button("Reply") { replying.toggle() } }
                if canResolve { Button(thread.root.isResolved ? "Reopen" : "Resolve", action: onResolve) }
                Spacer()
            }
            .font(.lexend(14, .medium))
            .foregroundStyle(Brand.green)
            .frame(minHeight: 44)
            if replying && canReply {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Reply", text: $replyText, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(8)
                        .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
                    Button("Send") {
                        Task {
                            if await onReply(replyText) {
                                replyText = ""
                                replying = false
                            }
                        }
                    }
                    .disabled(ReviewLogic.cleanComment(replyText) == nil)
                    .frame(minHeight: 44)
                }
                .font(.bodyText)
            }
        }
        .card(padding: 12)
        .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(selected ? Brand.green : Color.clear, lineWidth: 2))
        .opacity(thread.root.isResolved ? 0.7 : 1)
    }

    private func header(_ comment: ReviewComment) -> some View {
        HStack(spacing: 8) {
            switch comment.targetType {
            case .timecode:
                Text(ReviewLogic.timecode(comment.timeSeconds)).font(.mono(13, .medium)).foregroundStyle(Brand.green)
            case .framePin:
                PinMark(text: "\(number)", selected: selected)
                if showsTime {
                    Text(ReviewLogic.timecode(comment.timeSeconds)).font(.mono(13, .medium)).foregroundStyle(Brand.green)
                }
            case .general:
                EmptyView()
            }
            Text(comment.authorName ?? "Reviewer").font(.lexend(14, .semibold)).foregroundStyle(Brand.foreground)
            Text(comment.createdAt, format: .relative(presentation: .named)).font(.small).foregroundStyle(Brand.muted)
            Spacer()
            if comment.isResolved { StatusTag(text: "Resolved", tone: .success) }
            actions(for: comment)
        }
    }

    @ViewBuilder
    private func actions(for comment: ReviewComment) -> some View {
        if canEdit(comment) || canDelete(comment) {
            Menu {
                if canEdit(comment) { Button { onEdit(comment) } label: { Label("Edit", systemImage: "pencil") } }
                if canDelete(comment) {
                    Button(role: .destructive) { onDelete(comment) } label: { Label("Delete", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 32)
            }
            .foregroundStyle(Brand.muted)
            .accessibilityLabel("Comment actions")
        }
    }
}
