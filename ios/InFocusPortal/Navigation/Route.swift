import Foundation

/// Everything a NavigationStack can push. Each feature owns its own case enum
/// (in its folder), so adding a screen never edits this file.
enum Route: Hashable {
    case work(WorkRoute)
    case calendar(CalendarRoute)
    case grades(GradesRoute)
    case messages(MessagesRoute)
    case announcements(AnnouncementsRoute)
    case packageCycles(PackageCyclesRoute)
    case publishing(PublishingRoute)
    case gradeEditor(GradeEditorRoute)
    case meetings(MeetingsRoute)
    case more(MoreRoute)
    /// Any Portal page without a native screen, shown in the signed-in web view.
    case portal(PortalPage)
}

/// A Portal page to show in the in-app web view.
struct PortalPage: Hashable {
    let url: URL
    var title: String?
}

/// Where a deep link (notification tap, Portal link) lands.
struct DeepLinkMatch: Equatable {
    /// The tab to switch to; nil stays on the current tab.
    var tab: AppTab?
    /// The screen to push on that tab; nil shows the tab's root.
    var route: Route?
}
