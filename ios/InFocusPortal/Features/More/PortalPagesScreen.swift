import SwiftUI

/// Every Portal page this person can open. Pages with a native screen open
/// natively; the rest open in the signed-in Portal web view.
struct PortalPagesScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let user = session.user {
                ForEach(PortalPagesCatalog.sections(for: user, config: .shared)) { section in
                    Section(section.title) {
                        ForEach(section.links) { link in
                            Button { open(link) } label: {
                                Label(link.title, systemImage: link.systemImage)
                                    .foregroundStyle(Brand.foreground)
                            }
                            .accessibilityHint(link.external ? "Opens in Safari" : "")
                        }
                    }
                }
            }
        }
        .font(.bodyText)
        .scrollContentBackground(.hidden)
        .brandBackground()
        .navigationTitle("All Portal pages")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func open(_ link: PortalPageLink) {
        if link.external { return openURL(link.url) }
        guard let portal = router.portal else { return }
        let match = DeepLink.resolve(link.url, portal: portal)
        if let route = match.route {
            // Native or web, stay on More so Back returns here.
            router.push(route.isPortalPage ? .portal(PortalPage(url: link.url, title: link.title)) : route)
        } else {
            router.open(link.url) // a tab's root (Calendar, Home…)
        }
    }
}

extension Route {
    var isPortalPage: Bool {
        if case .portal = self { return true }
        return false
    }
}
