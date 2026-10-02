import Foundation

/// Screens of the Grade Editor feature (executives, the adviser and the super admin).
enum GradeEditorRoute: Hashable {
    /// The Grade Editor home (`/grade-editor`): cycle, totals, missing and participation.
    case home
    /// One person's grade for one cycle: Final Cut, check-ins, feedback, turned in, publish.
    case cycleStudent(cycle: Int, userId: String)
    /// One person's estimated semester grade (the web's Student view).
    case gradebook(userId: String)

    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["grade-editor"], ["grades", "grade-editor"]:
            return DeepLinkMatch(tab: .more, route: .gradeEditor(.home))
        default:
            return nil
        }
    }
}
