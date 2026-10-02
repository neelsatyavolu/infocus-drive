import SwiftUI

/// Messages tab root. Placeholder until the Messages agent's native chats
/// (on the website, chats live in the Portal panel beside the assistant).
struct MessagesTab: View {
    @Environment(Router.self) private var router

    var body: some View {
        ScrollView {
            EmptyStateView(title: "Messages",
                           message: "Group and direct chats are coming to the app. For now, open them in the Portal panel.",
                           actionTitle: "Open the Portal") {
                router.openPortal("dashboard", title: "Portal")
            }
            .padding(.top, 48)
        }
        .brandBackground()
        .navigationTitle("Messages")
    }
}
