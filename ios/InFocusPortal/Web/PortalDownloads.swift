import UIKit
import WebKit

/// Portal downloads land in a private folder, then open the share sheet
/// (Save to Files, Save Video, AirDrop, …).
final class PortalDownloads: NSObject, WKDownloadDelegate {
    private var destinations: [ObjectIdentifier: URL] = [:]

    /// A fresh folder per download keeps the suggested file name as-is.
    static func destination(for suggested: String, in root: URL) -> URL {
        let clean = (suggested as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
        let name = clean.isEmpty || clean == "." || clean == ".." ? "Download" : clean
        return root.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
        let url = Self.destination(for: suggestedFilename, in: root)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return completionHandler(nil)
        }
        destinations[ObjectIdentifier(download)] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        Task { @MainActor in Presenter.share(url) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        NSLog("InFocus: download failed: %@", error.localizedDescription)
        Task { @MainActor in
            let alert = UIAlertController(title: "Download failed", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            Presenter.present(alert)
        }
    }
}
