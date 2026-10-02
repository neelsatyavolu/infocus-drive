import SwiftUI

/// Screens for `GradeEditorRoute`.
struct GradeEditorDestination: View {
    let route: GradeEditorRoute

    var body: some View {
        switch route {
        case .home: PortalFallback(path: "grade-editor", title: "Grade Editor")
        }
    }
}
