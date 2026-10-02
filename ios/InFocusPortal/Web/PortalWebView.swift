import SwiftUI
import WebKit

/// Hosts the app's one Portal web view in SwiftUI.
struct PortalWebView: UIViewRepresentable {
    let controller: PortalWebController

    func makeUIView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
