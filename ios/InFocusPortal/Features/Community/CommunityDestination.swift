import SwiftUI

/// Screens for `CommunityRoute`.
struct CommunityDestination: View {
    let route: CommunityRoute

    var body: some View {
        switch route {
        case .ideas(let date): IdeasScreen(date: date)
        case .classBoard: ClassBoardScreen()
        }
    }
}
