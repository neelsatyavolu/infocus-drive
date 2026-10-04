import SwiftUI

struct MeetingsDestination: View {
    let route: MeetingsRoute

    var body: some View {
        switch route {
        case .home: MeetingsScreen()
        case .call(let id): MeetingCallScreen(meetingId: id) // normally presented full screen by Router
        }
    }
}
