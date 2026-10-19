import QuickLook
import SwiftUI

/// A file the Portal serves (a Slack attachment through `api/slack/files/<id>`), downloaded
/// signed in and shown with Quick Look, which also offers Share and Save to Files.
///
///     .sheet(item: $file) { PortalFileSheet(path: "api/slack/files/\($0.id)", title: $0.title) }
struct PortalFileSheet: View {
    let path: String
    let title: String

    @Environment(\.portalClient) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var state: Loadable<URL> = .idle

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loaded(let url):
                    QuickLookPreview(url: url).ignoresSafeArea(edges: .bottom)
                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }
                default:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Opening \(title)…").font(.small).foregroundStyle(Brand.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .brandBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let url = state.value {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share")
                    }
                }
            }
        }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await PortalFileDownload.fetch(path, fallbackName: title, client: client))
        } catch {
            state = .failed(Loadable<URL>.message(for: error))
        }
    }
}

/// Downloads a Portal file into a temporary folder, named as the Portal names it.
enum PortalFileDownload {
    static func fetch(_ path: String, fallbackName: String, client: PortalClient) async throws -> URL {
        if SampleMode.isOn { throw PortalError.sampleApp }
        let request = await client.request("GET", path)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await PortalClient.urlSession.data(for: request)
        } catch let error as URLError {
            throw PortalError.from(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PortalError.from(status: status, message: PortalJSON.errorMessage(data))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(fileName(response.suggestedFilename, fallback: fallbackName))
        try data.write(to: file, options: .atomic)
        return file
    }

    /// The server's name (from Content-Disposition), else the title, without path separators.
    static func fileName(_ suggested: String?, fallback: String) -> String {
        let name = [suggested, fallback, "attachment"]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "Unknown" } ?? "attachment"
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
