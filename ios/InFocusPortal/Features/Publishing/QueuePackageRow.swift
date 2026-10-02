import SwiftUI

/// What a producer can do to a queued package from a row's menu.
struct QueueRowActions {
    var move: (QueuePackage) -> Void
    var download: (QueuePackage) -> Void
    var remove: (QueuePackage) -> Void
}

/// One queued package: thumbnail, topic, headline, members, YouTube status.
/// Producers get a menu (move, download, remove); website managers only read.
struct QueuePackageRow: View {
    let package: QueuePackage
    var busy = false
    /// nil: read-only (website managers).
    var actions: QueueRowActions?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            QueueThumbnail(url: package.thumbnailUrl)
            VStack(alignment: .leading, spacing: 4) {
                Text(package.title)
                    .font(.h3)
                    .foregroundStyle(Brand.foreground)
                if let headline = package.distinctHeadline {
                    Text(headline).font(.small).foregroundStyle(Brand.secondary)
                }
                Text(QueueLogic.subtitle(custom: package.custom, cycleNumber: package.cycleNumber, members: package.members))
                    .font(.small)
                    .foregroundStyle(Brand.muted)
                let status = PublicationStatus.package(package.youtubePublication)
                StatusTag(text: "YouTube \(status.label)", tone: status.tone)
                    .padding(.top, 2)
                if let error = package.youtubePublication?.lastError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.small)
                        .foregroundStyle(Brand.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if busy {
                ProgressView().frame(width: 44, height: 44)
            } else if let actions {
                menu(actions)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func menu(_ actions: QueueRowActions) -> some View {
        Menu {
            Button("Move to another show", systemImage: "calendar") { actions.move(package) }
            Button("Download final cut", systemImage: "arrow.down.circle") { actions.download(package) }
            Button("Remove from queue", systemImage: "trash", role: .destructive) { actions.remove(package) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .foregroundStyle(Brand.secondary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Actions for \(package.title)")
    }
}

/// The final cut's poster, 16:9, or a quiet placeholder.
struct QueueThumbnail: View {
    let url: URL?
    var width: CGFloat = 96

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Brand.raised
                    Image(systemName: "film").foregroundStyle(Brand.muted)
                }
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
        .accessibilityHidden(true)
    }
}

/// The final cut's poster across the screen, 16:9.
struct QueuePoster: View {
    let url: URL?

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Brand.raised
                            Image(systemName: "film").font(.system(size: 28)).foregroundStyle(Brand.muted)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
            .accessibilityHidden(true)
    }
}

/// A show date's heading: its label and how full it is ("1/2").
struct QueueShowHeader: View {
    let label: String
    let count: Int
    /// Producers open the whole show's YouTube upload from here.
    var openShow: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Eyebrow(label, color: Brand.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text("\(count)/\(QueueLogic.maxPerShow)")
                .font(.mono(12, .medium))
                .monospacedDigit()
                .foregroundStyle(count >= QueueLogic.maxPerShow ? Brand.foreground : Brand.muted)
                .accessibilityLabel("\(count) of \(QueueLogic.maxPerShow) packages")
            if let openShow {
                Button(action: openShow) {
                    Label("Show upload", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Brand.green)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Whole show upload for \(label)")
            }
        }
    }
}
