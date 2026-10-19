import SwiftUI

/// A class page that isn't part of the App Review sample app.
struct NotInSampleApp: View {
    let title: String

    var body: some View {
        EmptyStateView(title: "Not available", message: "\(title) isn't part of the sample app.")
            .frame(maxHeight: .infinity)
            .brandBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
