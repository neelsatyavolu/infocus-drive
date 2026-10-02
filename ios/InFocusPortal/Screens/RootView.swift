import SwiftUI

/// Welcome while signed out, the Portal once signed in. The Portal's web view
/// stays alive underneath so returning to it never reloads more than needed.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Brand.background.ignoresSafeArea()
            if let web = model.web {
                PortalScreen(web: web)
                    .opacity(model.phase == .portal ? 1 : 0)
                    .allowsHitTesting(model.phase == .portal)
            }
            switch model.phase {
            case .launching:
                LaunchingView()
            case .welcome:
                WelcomeView()
                    .transition(.opacity)
            case .unconfigured:
                MessageView(title: "This build has no Portal address",
                            message: "Set INFOCUS_PORTAL_HOST in Config/Portal.local.xcconfig and build again.")
            case .portal:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.phase)
        .sheet(isPresented: $model.offeringNotifications) {
            NotificationOfferView()
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
        }
    }
}

/// Matches the launch screen (Ink with the mark) while the session is checked.
private struct LaunchingView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            Image("LaunchMark")
        }
    }
}
