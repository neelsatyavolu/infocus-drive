import SwiftUI

/// Screens for `WorkRoute`. Placeholders show the Portal page until the native screen lands.
struct WorkDestination: View {
    let route: WorkRoute

    var body: some View {
        switch route {
        case .group(let rowId, let stage):
            PortalPageScreen(path: ["groups", rowId, stage].compactMap { $0 }.joined(separator: "/"), title: "Group")
        case .studentStage(let stage):
            PortalPageScreen(path: stage.rawValue, title: stage.title)
        }
    }
}
