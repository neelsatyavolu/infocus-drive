import SwiftUI

/// Screens for `GradeEditorRoute`. Each checks access itself, since a deep link
/// can land on any of them.
struct GradeEditorDestination: View {
    let route: GradeEditorRoute

    var body: some View {
        GradeEditorAccessGate {
            switch route {
            case .home: GradeEditorScreen()
            case .cycleStudent(let cycle, let userId): StudentCycleEditor(cycleNumber: cycle, userId: userId)
            case .gradebook(let userId): StudentGradebookView(userId: userId)
            }
        }
    }
}

/// Executives, the adviser and the super admin only (`canManageGrades`, the web's
/// EXECUTIVE_PRODUCER check). Everyone else gets a quiet "not available".
struct GradeEditorAccessGate<Content: View>: View {
    @Environment(SessionStore.self) private var session
    @ViewBuilder var content: Content

    var body: some View {
        if session.user?.canManageGrades == true {
            content
        } else {
            EmptyStateView(title: "Not available",
                           message: "The Grade Editor is for executive producers, the adviser and the super admin.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .brandBackground()
                .navigationTitle("Grade Editor")
        }
    }
}
