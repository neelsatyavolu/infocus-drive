import SwiftUI

/// Packages (students) or Groups (producers) tab root. Placeholder until the
/// Work agent's native screens: producers see Groups, students their cycle.
struct WorkTab: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        if session.user?.isProducer == true {
            PortalPageScreen(path: "groups", title: "Groups")
        } else {
            PortalPageScreen(path: StudentStage.information.rawValue, title: "Packages")
        }
    }
}
