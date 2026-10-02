import Foundation

/// Screens of the Grade Editor feature. Owned by the Grade Editor agent.
enum GradeEditorRoute: Hashable {
    /// The Grade Editor home (`/grade-editor`).
    case home

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["grade-editor"], ["grades", "grade-editor"]:
            return DeepLinkMatch(tab: .more, route: .gradeEditor(.home))
        default:
            return nil
        }
    }
}
