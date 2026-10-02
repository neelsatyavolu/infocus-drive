import SwiftUI

/// A Portal page shown in the in-app web view until its native screen exists.
/// `path` is relative to the Portal (`"publishing-queue"`).
struct PortalFallback: View {
    let path: String
    let title: String

    var body: some View {
        if let portal = AppConfig.shared.portalURL, let url = URL(string: path, relativeTo: portal)?.absoluteURL {
            PortalPageScreen(page: PortalPage(url: url, title: title))
        } else {
            ErrorStateView(message: "The Portal address is missing from this build.", retry: {})
        }
    }
}
