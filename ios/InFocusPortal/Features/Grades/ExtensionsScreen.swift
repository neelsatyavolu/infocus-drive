import SwiftUI

/// Extensions: students request and track; producers review. Placeholder
/// (the Portal page) until the Grades agent's native screen.
struct ExtensionsScreen: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        if session.user?.isProducer == true {
            PortalPageScreen(path: "extension-requests", title: "Extension requests")
        } else {
            PortalPageScreen(path: "extensions", title: "Extensions")
        }
    }
}
