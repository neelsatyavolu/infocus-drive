import SwiftUI

/// Screens for `PackageCyclesRoute`.
struct PackageCyclesDestination: View {
    let route: PackageCyclesRoute

    var body: some View {
        switch route {
        case .home: PackageCyclesHome()
        case .cycle(let number): PackageCyclesHome(cycle: number)
        case .group(let rowId, let cycle): RosterGroupScreen(rowId: rowId, cycle: cycle)
        }
    }
}
