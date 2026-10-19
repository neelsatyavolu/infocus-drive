import SwiftUI

/// Screens for `GradesRoute`.
struct GradesDestination: View {
    let route: GradesRoute
    @Environment(SessionStore.self) private var session

    var body: some View {
        switch route {
        case .grades: GradesScreen()
        case .extensions: ExtensionsScreen()
        case .extensionRequest(let id): ExtensionRequestScreen(id: id)
        // Producer pages (the web sidebar's `producersOnly`); the Portal refuses everyone else too.
        case .members: producersOnly("Members") { MembersScreen() }
        case .participation: producersOnly("Participation") { ParticipationScreen() }
        }
    }

    @ViewBuilder private func producersOnly(_ title: String, @ViewBuilder _ screen: () -> some View) -> some View {
        if session.user?.isProducer == true {
            screen()
        } else {
            EmptyStateView(title: "Not available", message: "\(title) is for producers.")
                .frame(maxHeight: .infinity)
                .brandBackground()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
