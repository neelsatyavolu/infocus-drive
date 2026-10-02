import SwiftUI

/// A Portal page with no native screen yet, pushed in a tab (or as a tab's
/// root while a feature is being built): its own signed-in web view, the page
/// title as the navigation title, reload/back/share in the toolbar.
struct PortalPageScreen: View {
    let page: PortalPage
    @StateObject private var web: PortalWebController

    init(page: PortalPage) {
        self.page = page
        _web = StateObject(wrappedValue: PortalWebController.page(page.url))
    }

    /// A Portal path ("master-calendar") as a screen.
    init(path: String, title: String) {
        let portal = AppConfig.shared.portalURL ?? URL(string: "https://portal.invalid")!
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        self.init(page: PortalPage(url: URL(string: trimmed, relativeTo: portal)?.absoluteURL ?? portal, title: title))
    }

    var body: some View {
        ZStack(alignment: .top) {
            PortalWebView(controller: web)
            if web.isLoading {
                ProgressLine(progress: web.progress)
            }
            if let failure = web.failure {
                OfflineView(failure: failure) { web.retry(fallback: page.url) }
            }
        }
        .background(Brand.background)
        .navigationTitle(page.title ?? web.title ?? "Portal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if web.canGoBack {
                        Button("Back in this page", systemImage: "chevron.backward") { web.webView.goBack() }
                    }
                    Button("Reload", systemImage: "arrow.clockwise") { web.webView.reload() }
                    ShareLink(item: web.webView.url ?? page.url) { Label("Share link", systemImage: "square.and.arrow.up") }
                } label: {
                    Label("Page options", systemImage: "ellipsis")
                }
            }
        }
    }
}

extension PortalWebController {
    /// A web view for one pushed Portal page, already loading it.
    static func page(_ url: URL) -> PortalWebController {
        let controller = PortalWebController(portal: AppConfig.shared.portalURL ?? url, embedded: true)
        controller.delegate = AppModel.shared
        controller.load(url)
        return controller
    }
}

/// InFocus Green line along the top while a page loads.
struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Brand.green)
                .frame(width: proxy.size.width * max(0.08, progress), height: 2)
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
