import SwiftUI

/// Screens for `MessagesRoute`.
struct MessagesDestination: View {
    let route: MessagesRoute

    var body: some View {
        switch route {
        case .conversation(let id):
            ChatScreen(chatId: id)
        case .equipment:
            EquipmentScreen()
        case .livestreams:
            LivestreamsScreen()
        case .livestream(let id):
            LivestreamDetailScreen(eventId: id)
        }
    }
}
