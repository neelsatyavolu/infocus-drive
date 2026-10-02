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
    @State private var blocks = BlockList.shared
    /// Blocked people's messages shown again with a tap.
    @State private var revealed: Set<String> = []
    @State private var reportTarget: ReportTarget?
    @State private var blockCandidate: ChatPerson?
    @State private var offerReport: ReportTarget?

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
        .toolbar {
            if let peer = model.info.value?.peer {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        blockButton(peer)
                        if let latest = latestMessage(from: peer.id) {
                            Button("Report \(peer.name)", systemImage: "flag") { reportTarget = target(for: latest) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Conversation options")
                }
            }
        }
        .sheet(item: $reportTarget) { ReportSheet(target: $0) }
        .confirmationDialog("Block \(blockCandidate?.name ?? "")?",
                            isPresented: Binding(get: { blockCandidate != nil }, set: { if !$0 { blockCandidate = nil } }),
                            titleVisibility: .visible) {
            Button("Block", role: .destructive) { confirmBlock() }
        } message: {
            Text("Their messages are hidden on this iPhone (tap one to show it). They aren't told. Unblock in Settings.")
        }
        .alert("Report \(offerReport?.authorName ?? "them") too?",
               isPresented: Binding(get: { offerReport != nil }, set: { if !$0 { offerReport = nil } })) {
            Button("Report") {
                let target = offerReport
                offerReport = nil
                reportTarget = target
            }
            Button("Not now", role: .cancel) { offerReport = nil }
        } message: {
            Text("A report goes to the InFocus adviser and executive producers.")
        }
    }

    @ViewBuilder
    private func blockButton(_ person: ChatPerson) -> some View {
        if blocks.isBlocked(person.id) {
            Button("Unblock \(person.name)", systemImage: "person.crop.circle.badge.checkmark") { blocks.unblock(person.id) }
        } else {
            Button("Block \(person.name)", systemImage: "person.crop.circle.badge.xmark", role: .destructive) {
                blockCandidate = person
            }
        }
    }

    private func confirmBlock() {
        guard let person = blockCandidate else { return }
        blockCandidate = nil
        blocks.block(id: person.id, name: person.name)
        offerReport = latestMessage(from: person.id).map(target(for:))
    }

    private func latestMessage(from userId: String) -> ChatMessage? {
        model.messages.last { $0.authorId == userId }
    }

    private func target(for message: ChatMessage) -> ReportTarget {
        ReportTarget(report: .chat(message.id), authorName: message.author.name, excerpt: message.body)
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
            if !isMine && blocks.isBlocked(message.authorId) && !revealed.contains(message.id) {
                BlockedMessageRow { revealed.insert(message.id) }
            } else {
                MessageBubble(text: message.body, time: message.createdAt, isMine: isMine,
                              author: showsAuthor ? message.author.name : nil)
                    .contextMenu {
                        if !isMine {
                            Button("Report message", systemImage: "flag") { reportTarget = target(for: message) }
                            blockButton(message.author)
                        }
                    }
            }
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
