import SwiftUI

/// Screens for `PackageCyclesRoute`.
struct PackageCyclesDestination: View {
    let route: PackageCyclesRoute

    var body: some View {
        switch route {
        case .home: PortalFallback(path: "package-progress", title: "Package Cycles")
        }
    }
}
