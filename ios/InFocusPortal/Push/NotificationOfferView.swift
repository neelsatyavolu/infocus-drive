import SwiftUI

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
