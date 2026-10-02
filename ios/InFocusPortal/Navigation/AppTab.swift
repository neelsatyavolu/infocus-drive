import Foundation

/// The tab bar: Home · Packages (students) or Groups (producers) · Calendar · Messages · More.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home, work, calendar, messages, more

    var id: String { rawValue }

    /// The App Review sample account gets Home and More only.
    static func visible(for user: PortalUser?) -> [AppTab] {
        user?.sampleOnly == true ? [.home, .more] : allCases
    }

    func title(for user: PortalUser?) -> String {
        switch self {
        case .home: "Home"
        case .work: user?.isProducer == true ? "Groups" : "Packages"
        case .calendar: "Calendar"
        case .messages: "Messages"
        case .more: "More"
        }
    }

    func systemImage(for user: PortalUser?) -> String {
        switch self {
        case .home: "house"
        case .work: user?.isProducer == true ? "person.3" : "film.stack"
        case .calendar: "calendar"
        case .messages: "bubble.left.and.bubble.right"
        case .more: "ellipsis.circle"
        }
    }
}
