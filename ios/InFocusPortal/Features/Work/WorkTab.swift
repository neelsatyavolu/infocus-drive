import SwiftUI

/// Packages (students) or Groups (producers). An associate producer who is also
/// on a package this cycle gets both, switched at the top (like the web sidebar).
struct WorkTab: View {
    @Environment(SessionStore.self) private var session
    @State private var showGroups = true

    var body: some View {
        let user = session.user
        Group {
            if user?.isProducer == true && user?.doesStudentWork == true {
                VStack(spacing: 0) {
                    Picker("Show", selection: $showGroups) {
                        Text("Groups").tag(true)
                        Text("My package").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Brand.gutter)
                    .padding(.vertical, 8)
                    if showGroups { GroupsScreen() } else { PackagesScreen() }
                }
                .brandBackground()
            } else if user?.isProducer == true {
                GroupsScreen()
            } else {
                PackagesScreen()
            }
        }
    }
}
