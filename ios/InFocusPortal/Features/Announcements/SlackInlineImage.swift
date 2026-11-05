import SwiftUI
import UIKit

/// A Slack image attachment drawn inline at its own shape, inside 400×320 like the web feed
/// (`AttachmentImage` in `components/announcements/slack-feed.tsx`). It loads signed in through the
/// Portal's file proxy (`SlackFiles`); a tap opens it in Quick Look. Anything that isn't a picture
/// after all falls back to the attachment row.
struct SlackInlineImage<Fallback: View>: View {
    let file: SlackPost.Attachment
    let size: SlackPost.Attachment.ImageSize
    let open: (URL) -> Void
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.portalClient) private var client
    @State private var loaded: SlackImageCache.Entry?
    @State private var failed = false

    var body: some View {
        if failed {
            fallback()
        } else {
            let box = Self.fit(size)
            Button {
                if let loaded { open(loaded.file) }
            } label: {
                Brand.raised
                    .aspectRatio(box.width / box.height, contentMode: .fit)
                    .frame(maxWidth: box.width)
                    .overlay {
                        if let loaded {
                            Image(uiImage: loaded.image).resizable().scaledToFill()
                        } else {
                            ProgressView()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
            }
            .buttonStyle(.plain)
            .disabled(loaded == nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(file.title)
            .accessibilityAddTraits(.isImage)
            .accessibilityHint("Opens the image")
            .task(id: file.id) { await load() }
        }
    }

    private func load() async {
        if let cached = SlackImageCache.shared.entry(file.id) {
            loaded = cached
            return
        }
        do {
            let url = try await AnnouncementsAPI.current(client).slackFile(file.id, file.title)
            guard let image = UIImage(contentsOfFile: url.path) else {
                failed = true
                return
            }
            let entry = SlackImageCache.Entry(image: image, file: url)
            SlackImageCache.shared.store(entry, for: file.id)
            loaded = entry
        } catch {
            failed = true
        }
    }

    /// The image's size scaled down (never up) to fit 400×320 points.
    static func fit(_ size: SlackPost.Attachment.ImageSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 400, height: 320) }
        let scale = min(1, 400 / size.width, 320 / size.height)
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }
}

/// Inline images already downloaded this session, so scrolling the feed doesn't fetch them again.
final class SlackImageCache: @unchecked Sendable {
    final class Entry: Equatable {
        let image: UIImage
        let file: URL

        init(image: UIImage, file: URL) {
            self.image = image
            self.file = file
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs === rhs }
    }

    static let shared = SlackImageCache()
    private let cache = NSCache<NSString, Entry>()

    init() { cache.countLimit = 60 }

    /// Nil when it isn't cached or its file is gone (Quick Look opens the file).
    func entry(_ id: String) -> Entry? {
        guard let entry = cache.object(forKey: id as NSString) else { return nil }
        return FileManager.default.fileExists(atPath: entry.file.path) ? entry : nil
    }

    func store(_ entry: Entry, for id: String) {
        cache.setObject(entry, forKey: id as NSString)
    }
}
