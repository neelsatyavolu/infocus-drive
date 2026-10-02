import SwiftUI

/// One group on the roster: topic, members, assigned producer and stage progress.
struct RosterGroupCard: View {
    let row: RosterRow
    let assigned: String?
    let repeated: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.topic.isEmpty ? "No topic yet" : row.topic)
                    .headline(.h3)
                    .foregroundStyle(row.topic.isEmpty ? Brand.muted : Brand.foreground)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.muted)
                    .accessibilityHidden(true)
            }
            Text(row.members.isEmpty ? "No members" : row.members.map(\.name).joined(separator: ", "))
                .font(.small)
                .foregroundStyle(row.members.isEmpty ? Brand.muted : Brand.secondary)
            RosterStageTrack(row: row)
            RosterGroupTags(row: row, assigned: assigned)
            if !repeated.isEmpty {
                Label("Same group last cycle: \(repeated.joined(separator: " and "))", systemImage: "exclamationmark.triangle")
                    .font(.small)
                    .foregroundStyle(Brand.warning)
            }
        }
        .card()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The five stages as a compact track, done stages filled green.
struct RosterStageTrack: View {
    let row: RosterRow

    var body: some View {
        let done = Set(RosterStage.done(row))
        HStack(spacing: 4) {
            ForEach(RosterStage.allCases) { stage in
                VStack(spacing: 4) {
                    Rectangle()
                        .fill(done.contains(stage) ? Brand.green : Brand.raised)
                        .frame(height: 4)
                    Text(stage.shortTitle)
                        .font(.lexend(10, .medium, relativeTo: .caption2))
                        .foregroundStyle(done.contains(stage) ? Brand.secondary : Brand.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RosterStage.current(row).map { "Working on \($0.title)" } ?? "All stages done")
    }
}

/// Assigned producer and status tags.
private struct RosterGroupTags: View {
    let row: RosterRow
    let assigned: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { tags }
            VStack(alignment: .leading, spacing: 6) { tags }
        }
    }

    @ViewBuilder private var tags: some View {
        StatusTag(text: assigned ?? "Unassigned", tone: assigned == nil ? .warning : .neutral)
        if row.isPackageOfCycle { StatusTag(text: "Package of the Cycle", tone: .success) }
        if row.queuedForAir { StatusTag(text: "Queued", tone: .success) }
        if row.hasExtension { StatusTag(text: "Extension", tone: .warning) }
    }
}
