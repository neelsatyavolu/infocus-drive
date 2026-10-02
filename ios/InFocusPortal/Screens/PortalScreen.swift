import SwiftUI

/// The Portal web view with a thin green progress line, the offline screen
/// when it can't load, and a way back from the email sign-in page.
struct PortalScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var web: PortalWebController

    var body: some View {
        ZStack(alignment: .top) {
            PortalWebView(controller: web)
                .ignoresSafeArea() // the Portal pads for the safe area itself (viewport-fit=cover)
            if web.isLoading {
                ProgressLine(progress: web.progress)
            }
            if model.usingEmailSignIn {
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
            }
            if let failure = web.failure {
                OfflineView(failure: failure) {
                    if let home = model.config.homeURL { web.retry(fallback: home) }
                }
            }
        }
    }
}

/// InFocus Green line under the status bar while a page loads.
private struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Brand.green)
                .frame(width: proxy.size.width * max(0.08, progress), height: 2)
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
