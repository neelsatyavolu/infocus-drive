import SwiftUI

/// One video or image in a project: thumbnail, title, version, status and comment count.
struct MediaRow: View {
    let item: ReviewMedia
    let api: ReviewAPI
    var busy = false

    var body: some View {
        HStack(spacing: 12) {
            MediaThumb(item: item, api: api)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Brand.tagRadius))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.lexend(15, .medium))
                    .foregroundStyle(Brand.foreground)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let version = item.currentVersion {
                        Text("V\(version.versionNumber)").font(.mono(12, .medium)).foregroundStyle(Brand.secondary)
                        if let state = ReviewLogic.label(version.status) {
                            StatusTag(text: state, tone: version.status == .failed ? .danger : .neutral)
                        } else {
                            StatusTag(text: ReviewLogic.label(version.approvalStatus), tone: tone(version.approvalStatus))
                        }
                        if version.commentCount > 0 {
                            Label("\(version.commentCount)", systemImage: "text.bubble")
                                .font(.mono(12))
                                .foregroundStyle(Brand.muted)
                                .accessibilityLabel("\(version.commentCount) comments")
                        }
                    }
                }
                if let deletedAt = item.deletedAt {
                    Text("Deleted \(deletedAt.formatted(.relative(presentation: .named)))\(item.deletedBy.map { " by \($0.label)" } ?? "")")
                        .font(.small)
                        .foregroundStyle(Brand.muted)
                }
            }
            Spacer(minLength: 0)
            if busy { ProgressView() }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private func tone(_ status: ReviewApproval) -> StatusTag.Tone {
        switch status {
        case .approved, .aired: .success
        case .needsChanges: .warning
        case .inReview: .neutral
        }
    }
}

/// An image's own picture (signed-in only, fetched with the session), or a film mark for video.
struct MediaThumb: View {
    let item: ReviewMedia
    let api: ReviewAPI
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Brand.raised
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.currentVersion?.isImage == true ? "photo" : "film").foregroundStyle(Brand.muted)
            }
        }
        .accessibilityHidden(true)
        .task(id: item.currentVersion?.id) {
            guard let version = item.currentVersion, version.isImage, image == nil else { return }
            if let data = try? await api.image(item.id, version.id) { image = UIImage(data: data) }
        }
    }
}

/// Sets a version to Aired on a chosen date (the Portal requires one).
struct AiredDateSheet: View {
    let onSave: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Aired on", selection: $date, in: ...Date(), displayedComponents: .date)
                    .font(.bodyText)
            }
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Mark as aired")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(date)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
