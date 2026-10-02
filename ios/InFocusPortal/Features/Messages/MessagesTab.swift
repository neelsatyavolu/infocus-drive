import SwiftUI

/// Messages tab: package group chats and direct messages, newest first.
struct MessagesTab: View {
    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @Environment(BadgeCenter.self) private var badges
    @State private var model: InboxModel?
    @State private var composing = false

    var body: some View {
        Group {
            if let model {
                InboxList(model: model, open: open)
            } else {
                ScrollView { SkeletonList().padding(Brand.gutter) }
            }
        }
        .brandBackground()
        .navigationTitle("Messages")
        .toolbar {
            if model?.state.value?.canStartDirect == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New message")
                }
            }
        }
        .sheet(isPresented: $composing) {
            if let model, let inbox = model.state.value {
                NewMessageSheet(people: inbox.members) { person in
                    composing = false
                    Task {
                        if let id = await model.open(.direct(userId: person.id), key: person.id) {
                            router.push(.messages(.conversation(id: id)))
                        }
                    }
                }
            }
        }
        .alert("Couldn't open that chat", isPresented: Binding(
            get: { model?.openError != nil }, set: { if !$0 { model?.openError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model?.openError ?? "")
        }
        .task {
            let model = self.model ?? InboxModel(service: .resolve(client))
            self.model = model
            if let unread = await model.load() { badges.set(unread, for: .messages) }
            await model.poll { badges.set($0, for: .messages) }
        }
    }

    private func open(_ chat: ChatSummary) {
        guard let model else { return }
        Task {
            if let id = await model.chatId(for: chat) {
                router.push(.messages(.conversation(id: id)))
            }
        }
    }
}

private struct InboxList: View {
    @Bindable var model: InboxModel
    let open: (ChatSummary) -> Void

    var body: some View {
        LoadableView(model.state, retry: { Task { await model.load() } }) { inbox in
            if inbox.chats.isEmpty {
                ScrollView {
                    EmptyStateView(title: "No chats yet",
                                   message: "Each package you're on gets a group chat with its producer. They show up here.")
                        .padding(.top, 48)
                }
            } else {
                List {
                    ForEach(model.chats) { chat in
                        Button { open(chat) } label: {
                            InboxRow(chat: chat, isOpening: model.opening == chat.id)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: Brand.gutter, bottom: 4, trailing: Brand.gutter))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .searchable(text: $model.query, prompt: "Search chats")
                .overlay {
                    if model.chats.isEmpty {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
        }
        .refreshable { await model.load() }
    }
}
