import SwiftUI

/// Welcome while signed out, the Portal's email sign-in page when chosen, and
/// the native tabs once signed in. Hands the shared stores to every screen.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            switch model.phase {
            case .launching:
                LaunchingView()
            case .welcome:
                WelcomeView()
                    .transition(.opacity)
            case .emailSignIn:
                if let web = model.signInWeb { EmailSignInScreen(web: web) }
            case .signedIn:
                SignedInRoot()
                    .transition(.opacity)
            case .unconfigured:
                MessageView(title: "This build has no Portal address",
                            message: "Set INFOCUS_PORTAL_HOST in Config/Portal.local.xcconfig and build again.")
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.phase)
        .environment(model.session)
        .environment(model.router)
        .environment(model.badges)
        .environment(model.preferences)
        .environment(\.portalClient, model.client)
        .preferredColorScheme(model.preferences.appearance.colorScheme)
        .sheet(isPresented: $model.offeringNotifications) {
            NotificationOfferView()
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
        }
    }
}

/// The tabs once we know who's signed in; a quiet launch screen until then,
/// and a retry if the Portal couldn't be reached.
private struct SignedInRoot: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.portalClient) private var client

    var body: some View {
        switch session.state {
        case .loaded:
            MainTabView()
        case .failed(let message):
            ErrorStateView(title: "Couldn't reach the Portal", message: message) {
                Task { await session.load(using: client) }
            }
            .frame(maxHeight: .infinity)
            .brandBackground()
        case .idle, .loading:
            LaunchingView()
        }
    }
}

/// Matches the launch screen (Ink with the mark) while the session is checked.
struct LaunchingView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            Image("LaunchMark")
        }
    }
}
