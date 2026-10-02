import SwiftUI

/// Screens for `GradesRoute`.
struct GradesDestination: View {
    let route: GradesRoute

    var body: some View {
        switch route {
        case .grades: GradesScreen()
        case .extensions: ExtensionsScreen()
        case .extensionRequest(let id): ExtensionRequestScreen(id: id)
        }
    }
}
