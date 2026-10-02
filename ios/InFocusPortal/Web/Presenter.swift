import SafariServices
import UIKit

/// Presents UIKit sheets (alerts, Safari, share) from non-view code, on top
/// of whatever is showing.
@MainActor
enum Presenter {
    static var top: UIViewController? {
        var controller = UIApplication.shared.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }

    /// `orElse` runs when nothing can show the sheet (so a web panel never hangs).
    static func present(_ controller: UIViewController, orElse fallback: (() -> Void)? = nil) {
        guard let top else {
            fallback?()
            return
        }
        top.present(controller, animated: true)
    }

    static func showSafari(_ url: URL) {
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = Brand.uiGreen
        safari.dismissButtonStyle = .close
        present(safari)
    }

    static func share(_ fileURL: URL) {
        let sheet = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        // iPad shows it as a popover; anchor it mid-screen.
        if let popover = sheet.popoverPresentationController, let view = top?.view {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet)
    }
}
