import Foundation

/// Screens of the Grade Editor feature (executives, the adviser and the super admin).
enum GradeEditorRoute: Hashable {
    /// The Grade Editor home (`/grade-editor`): cycle, totals, missing and participation.
    case home
    /// The Grade Editor open on Participation (`/grade-editor?view=participation`, and the old
    /// `/participation` page, which the Portal now redirects there).
    case participation
    /// One person's grade for one cycle: Final Cut, check-ins, feedback, turned in, publish.
    case cycleStudent(cycle: Int, userId: String)
    /// One person's estimated semester grade (the web's Student view).
    case gradebook(userId: String)

    /// `/grade-editor[?view=participation]` and `/participation` (also on the grades host:
    /// `grades.` → `["grades", …]`).
    static func deepLink(_ path: [String], _ query: [URLQueryItem]) -> DeepLinkMatch? {
        switch path {
        case ["grade-editor"], ["grades", "grade-editor"]:
            let participation = query.contains { $0.name == "view" && $0.value == "participation" }
            return DeepLinkMatch(tab: .more, route: .gradeEditor(participation ? .participation : .home))
        case ["participation"], ["grades", "participation"]:
            return DeepLinkMatch(tab: .more, route: .gradeEditor(.participation))
        default:
            return nil
        }
    }
}
