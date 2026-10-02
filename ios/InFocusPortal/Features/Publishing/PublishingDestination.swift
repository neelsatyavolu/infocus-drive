import SwiftUI

/// Screens for `PublishingRoute`.
struct PublishingDestination: View {
    let route: PublishingRoute

    var body: some View {
        switch route {
        case .home: PortalFallback(path: "publishing-queue", title: "Publishing Queue")
        }
    }
}
