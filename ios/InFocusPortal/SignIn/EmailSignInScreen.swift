import SwiftUI

/// The Portal's own email-code sign-in page, full screen, with a way back to
/// the welcome screen. Once a session appears the app switches to the tabs.
struct EmailSignInScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var web: PortalWebController

    var body: some View {
        ZStack(alignment: .top) {
            PortalWebView(controller: web)
                .ignoresSafeArea() // the Portal pads for the safe area itself (viewport-fit=cover)
            if web.isLoading {
                ProgressLine(progress: web.progress)
            }
            Button {
                model.backToWelcome()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.lexend(15, .medium))
                    .foregroundStyle(Brand.foreground)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            if let failure = web.failure {
                OfflineView(failure: failure) {
                    model.signInWithEmail()
                }
            }
        }
    }
}
