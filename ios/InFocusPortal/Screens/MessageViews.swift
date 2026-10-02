import SwiftUI

/// Empty-state layout (DESIGN.md §10): the mark, one SemiBold line, one
/// secondary line, and at most one primary button.
struct MessageView: View {
    let title: String
    let message: String
    var systemImage: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Brand.muted)
                    .frame(height: 64)
            } else {
                Image("BrandMark").resizable().frame(width: 64, height: 64)
            }
            Text(title)
                .font(.lexend(20, .semibold, relativeTo: .title3))
                .foregroundStyle(Brand.foreground)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.lexend(15))
                .foregroundStyle(Brand.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.background.ignoresSafeArea())
    }
}

/// Shown instead of a blank page when the Portal can't load.
struct OfflineView: View {
    let failure: PortalLoadFailure
    let retry: () -> Void

    var body: some View {
        switch failure {
        case .offline:
            MessageView(title: "You're offline",
                        message: "Connect to Wi-Fi or cellular data, then try again.",
                        systemImage: "wifi.slash",
                        action: ("Try again", retry))
        case .unavailable:
            MessageView(title: "The Portal isn't responding",
                        message: "It may be updating. Try again in a minute.",
                        systemImage: "exclamationmark.triangle",
                        action: ("Try again", retry))
        }
    }
}

/// Asked once, right after the first sign-in, before iOS's own prompt.
struct NotificationOfferView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "bell.badge")
                .font(.system(size: 30))
                .foregroundStyle(Brand.green)
            Text("Get Portal notifications")
                .font(.lexend(22, .semibold, relativeTo: .title2))
                .foregroundStyle(Brand.foreground)
            Text("Approvals, feedback on your package, deadlines and messages: the same things the Portal emails you about, on this device. Change it any time in Settings.")
                .font(.lexend(15))
                .foregroundStyle(Brand.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Turn on notifications") { model.answerNotificationsOffer(turnOn: true) }
                .buttonStyle(PrimaryButtonStyle())
            Button("Not now") { model.answerNotificationsOffer(turnOn: false) }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.card.ignoresSafeArea())
    }
}

#Preview("Offline") {
    OfflineView(failure: .offline) {}
}
