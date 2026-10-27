import SwiftUI

/// Screens for `CalendarRoute`.
struct CalendarDestination: View {
    let route: CalendarRoute

    var body: some View {
        switch route {
        case .day(let date):
            DayDetailView(date: date)
        case .theShow:
            TheShowView()
        case .showUpload(let date):
            ShowUploadView(date: date)
        case .teleprompter(let showDate, let docId):
            TeleprompterScreen(showDate: showDate, docId: docId)
        case .editing(let date):
            EditingScreen(date: date)
        }
    }
}
