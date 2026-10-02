import SwiftUI

/// A card heading for an editable job, with an optional action on the right (Randomize, Use rotation).
struct CastSectionHeader: View {
    let title: String
    var detail: String?
    var action: (label: String, systemImage: String, run: () -> Void)?
    var disabled = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(title, color: Brand.muted)
                if let detail { Text(detail).font(.small).foregroundStyle(Brand.muted) }
            }
            Spacer()
            if let action {
                Button(action: action.run) {
                    Label(action.label, systemImage: action.systemImage)
                        .font(.lexend(14, .medium, relativeTo: .subheadline))
                        .frame(minHeight: 36)
                }
                .foregroundStyle(Brand.green)
                .disabled(disabled)
            }
        }
    }
}

/// One slot (Anchor 1, Show manager…): the name, or a placeholder, opening the picker.
struct CastSlotRow: View {
    let placeholder: String
    let value: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(value.isEmpty ? placeholder : value)
                    .font(.lexend(16, value.isEmpty ? .regular : .medium, relativeTo: .body))
                    .foregroundStyle(value.isEmpty ? Brand.muted : Brand.foreground)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(Brand.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(placeholder)
        .accessibilityValue(value.isEmpty ? "Not set" : value)
        .accessibilityHint("Opens the list of names")
    }
}

/// A crew list (Lunch filmers, Editors…): removable name chips and an Add button.
struct CrewChips: View {
    let names: [String]
    /// Nil for the old unsorted "Filmers" list, which can only shrink.
    let addLabel: String?
    var disabled = false
    let onRemove: (String) -> Void
    let onAdd: () -> Void

    var body: some View {
        CrewFlow(spacing: 6) {
            ForEach(names, id: \.self) { name in
                Button { onRemove(name) } label: {
                    HStack(spacing: 4) {
                        Text(name).font(.lexend(14, relativeTo: .subheadline))
                        Image(systemName: "xmark").font(.caption2.weight(.semibold)).foregroundStyle(Brand.muted)
                    }
                    .foregroundStyle(Brand.foreground)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 36)
                    .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.tagRadius))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityLabel("Remove \(name)")
            }
            if let addLabel {
                Button(action: onAdd) {
                    Label(addLabel, systemImage: "plus")
                        .font(.lexend(14, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Brand.green)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 36)
                        .overlay(RoundedRectangle(cornerRadius: Brand.tagRadius).strokeBorder(Brand.line))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
        }
    }
}

/// Lays chips out in rows that wrap.
struct CrewFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width.isFinite ? width : rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for (index, x) in zip(row.indices, row.xs) {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var indices: [Int] = []; var xs: [CGFloat] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            let x = row.indices.isEmpty ? 0 : row.width + spacing
            row.indices.append(index)
            row.xs.append(x)
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// An error from the Portal, in its words, with the icon (never color alone).
struct EditErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.small)
            .foregroundStyle(Brand.danger)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.dangerTint, in: RoundedRectangle(cornerRadius: Brand.radius))
            .accessibilityLabel("Couldn't save: \(message)")
    }
}
