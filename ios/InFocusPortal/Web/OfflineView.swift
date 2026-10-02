import SwiftUI

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

#Preview("Offline") {
    OfflineView(failure: .offline) {}
}
