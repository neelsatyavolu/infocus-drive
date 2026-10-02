import SwiftUI

/// One conversation: messages oldest to newest, composer at the bottom, live every 4 s.
struct ChatScreen: View {
    let chatId: String
    @Environment(\.portalClient) private var client
    @State private var model: ChatModel?

    var body: some View {
        Group {
            if let model {
                ChatContent(model: model)
            } else {
                ScrollView { SkeletonList(rows: 4).padding(Brand.gutter) }
            }
        }
        .brandBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let info = model?.info.value {
                    VStack(spacing: 1) {
                        Text(info.title).font(.lexend(16, .semibold, relativeTo: .headline)).lineLimit(1)
                        Text(info.subtitle).font(.lexend(12, relativeTo: .caption)).foregroundStyle(Brand.muted).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .task(id: chatId) {
            let model = self.model ?? ChatModel(chatId: chatId, service: .resolve(client))
            self.model = model
            await model.load()
            await model.poll()
        }
    }
}

private struct ChatContent: View {
    @Bindable var model: ChatModel

    var body: some View {
        LoadableView(model.info, retry: { Task { await model.load() } }) { _ in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if model.messages.isEmpty && model.pending.isEmpty {
                            Text("No messages yet. Say hi.")
                                .font(.small)
                                .foregroundStyle(Brand.muted)
                                .padding(.top, 40)
                        }
                        ForEach(model.rows) { row in
                            rowView(row).id(row.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.rows.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                ChatComposer(text: $model.draft, canSend: model.canSend) {
                    Task { await model.send() }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case .day(_, let title):
            Eyebrow(title, color: Brand.muted, size: 11)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .accessibilityAddTraits(.isHeader)
        case .message(let message, let isMine, let showsAuthor):
            MessageBubble(text: message.body, time: message.createdAt, isMine: isMine,
                          author: showsAuthor ? message.author.name : nil)
        case .pending(let pending):
            MessageBubble(text: pending.body, time: pending.createdAt, isMine: true, author: nil, pending: pending.status)
                .onTapGesture {
                    if case .failed = pending.status { Task { await model.retry(pending) } }
                }
                .contextMenu {
                    if case .failed = pending.status {
                        Button("Try again") { Task { await model.retry(pending) } }
                        Button("Delete", role: .destructive) { model.discard(pending) }
                    }
                }
        }
    }
}
