import SwiftUI

/// Screens for `MessagesRoute`.
struct MessagesDestination: View {
    let route: MessagesRoute

    var body: some View {
        switch route {
        case .conversation:
            MessagesTab()
        case .equipment:
            EquipmentScreen()
        case .livestreams, .livestream:
            LivestreamsScreen()
        }
    }
}
