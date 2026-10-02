import SwiftUI

/// Screens for `PublishingRoute`.
struct PublishingDestination: View {
    let route: PublishingRoute

    var body: some View {
        switch route {
        case .home: PublishingScreen()
        case .package(let rowId): QueuePackageScreen(rowId: rowId)
        case .show(let date): ShowUploadScreen(date: date)
        case .managers: PublishingManagersScreen()
        }
    }
}
