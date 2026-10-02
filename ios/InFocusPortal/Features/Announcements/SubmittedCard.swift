import SwiftUI

/// One submitted announcement, as the web card shows it: where it runs, its dates, the text,
/// who sent it, and Media / More info links. Copy and (for producers) Delete.
struct SubmittedCard: View {
    let entry: SubmittedEntry
    let canDelete: Bool
    let deleting: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if !entry.destination.isEmpty {
                        Text(entry.destination).font(.lexend(13, .semibold, relativeTo: .footnote))
                    }
                    Label(SubmittedDates.range(entry), systemImage: "calendar")
                        .font(.small)
                        .foregroundStyle(Brand.muted)
                }
                Spacer(minLength: 8)
                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc").font(.lexend(14, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.green)
                .frame(minHeight: 44)
                .accessibilityLabel("Copy announcement")
            }
            Text(entry.announcement)
                .font(.bodyText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            notes
            footer
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Text(deleting ? "Deleting…" : "Delete")
                }
                .buttonStyle(QuietDestructiveButtonStyle())
                .disabled(deleting)
            }
        }
        .card()
    }

    @ViewBuilder
    private var notes: some View {
        let media = entry.mediaLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = entry.moreInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !media.isEmpty, SubmittedDates.link(media) == nil {
            Text(media).font(.small).foregroundStyle(Brand.secondary)
        }
        if !info.isEmpty, SubmittedDates.link(info) == nil {
            Text(info).font(.small).foregroundStyle(Brand.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([entry.name.isEmpty ? "Unknown submitter" : entry.name, entry.submitterRole]
                .filter { !$0.isEmpty }.joined(separator: " · "))
            if let mail = URL(string: "mailto:\(entry.email)"), !entry.email.trimmingCharacters(in: .whitespaces).isEmpty {
                Link(entry.email, destination: mail).foregroundStyle(Brand.green)
            }
            Text("Submitted \(SubmittedDates.submitted(entry.submittedAt))")
            HStack(spacing: 16) {
                if let url = SubmittedDates.link(entry.mediaLink) {
                    Button { openURL(url) } label: { Label("Media", systemImage: "arrow.up.right") }
                }
                if let url = SubmittedDates.link(entry.moreInfo) {
                    Button { openURL(url) } label: { Label("More info", systemImage: "arrow.up.right") }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.green)
        }
        .font(.small)
        .foregroundStyle(Brand.muted)
    }
}
