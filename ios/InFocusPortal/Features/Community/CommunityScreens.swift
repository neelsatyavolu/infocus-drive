import SwiftUI

/// Story ideas from around the Bay (`/ideas`). The Portal renders the sets on the server and has
/// no JSON API for them yet, so the page shows in the signed-in web view.
struct IdeasScreen: View {
    let date: String?
    @Environment(SessionStore.self) private var session

    var body: some View {
        if session.user?.sampleOnly == true {
            NotInSampleApp(title: "Ideas")
        } else {
            PortalFallback(path: IdeasPage.path(date: date), title: "Ideas")
        }
    }
}

/// The Class Board (`/class-board`): the classroom display in the signed-in web view (the Portal
/// draws it on the server), with native board settings for producers.
struct ClassBoardScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var showingSettings = false

    var body: some View {
        if session.user?.sampleOnly == true {
            NotInSampleApp(title: "Class Board")
        } else {
            PortalFallback(path: "class-board", title: "Class Board")
                .toolbar {
                    if session.user?.isProducer == true {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showingSettings = true } label: {
                                Label("Board settings", systemImage: "slider.horizontal.3")
                            }
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) { ClassBoardSettingsSheet() }
        }
    }
}

/// A web-only page in the App Review sample app.
private struct NotInSampleApp: View {
    let title: String

    var body: some View {
        EmptyStateView(title: "Not available", message: "\(title) isn't part of the sample app.")
            .frame(maxHeight: .infinity)
            .brandBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
