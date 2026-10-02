import SwiftUI

/// Signed out: sign in with the school Google account through the browser,
/// or with an emailed code on the Portal's own page.
struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: 20) {
                Image("Wordmark")
                    .accessibilityLabel("InFocus")
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Portal")
                    Text("Your packages, grades, scripts and the show, in one place.")
                        .font(.lexend(26, .semibold, relativeTo: .title))
                        .tracking(-0.4)
                        .foregroundStyle(Brand.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The plate's green strip (DESIGN.md §10: the web nameplate).
                Rectangle().fill(Brand.fill).frame(width: 48, height: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 48)
            VStack(spacing: 12) {
                if let error = model.signInError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.lexend(14, relativeTo: .footnote))
                        .foregroundStyle(Brand.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isStaticText)
                }
                Button {
                    model.signInWithSchoolAccount()
                } label: {
                    HStack(spacing: 10) {
                        if model.signingIn { ProgressView().tint(Brand.onBrand) }
                        Text(model.signingIn ? "Signing in…" : "Sign in with your school account")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.signingIn)
                Button("Sign in with an email code") {
                    model.signInWithEmail()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.signingIn)
                Text("For InFocus members at Palo Alto High School.")
                    .font(.lexend(13, relativeTo: .footnote))
                    .foregroundStyle(Brand.muted)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.background.ignoresSafeArea())
    }
}

#Preview("Welcome") {
    WelcomeView().environmentObject(AppModel.shared)
}
