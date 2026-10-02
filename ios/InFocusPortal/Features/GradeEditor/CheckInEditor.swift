import SwiftUI

/// The four check-ins for one person and cycle. Each saves as soon as it's
/// picked, like the web (`setCheckIn`). Not-yet-released cells show N/A.
struct CheckInEditor: View {
    let row: CycleGradeRow
    let busy: Bool
    let onChange: (CheckInStage, GradeEditorLogic.CheckInChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Check-ins")
            ForEach(CheckInStage.allCases) { stage in
                HStack {
                    Text(stage.label).font(.bodyText)
                    Spacer()
                    if let released = row.checkInScores?[stage] {
                        menu(stage, released: released)
                    } else {
                        Text("N/A")
                            .font(.mono(14))
                            .foregroundStyle(Brand.muted)
                            .accessibilityLabel("Not released yet")
                    }
                }
                .frame(minHeight: 44)
                if stage != CheckInStage.allCases.last { Divider().overlay(Brand.line) }
            }
            Text("Automatic is the released score. Pick a number, Ungraded or Exempt to override it.")
                .font(.small)
                .foregroundStyle(Brand.muted)
                .padding(.top, 4)
        }
        .card()
    }

    private func menu(_ stage: CheckInStage, released: CheckInValue) -> some View {
        let current = GradeEditorLogic.choice(override: row.checkInOverrides?[stage])
        return Menu {
            ForEach(GradeEditorLogic.CheckInChoice.all) { choice in
                Button {
                    onChange(stage, choice)
                } label: {
                    if choice == current {
                        Label(label(choice, released: released), systemImage: "checkmark")
                    } else {
                        Text(label(choice, released: released))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(released.label).font(.mono(15, .medium))
                if current != .automatic {
                    StatusTag(text: "Override", tone: .warning)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Brand.muted)
            }
            .frame(minHeight: 44)
        }
        .disabled(busy)
        .accessibilityLabel("\(stage.label): \(released.label)\(current == .automatic ? "" : ", overridden")")
    }

    private func label(_ choice: GradeEditorLogic.CheckInChoice, released: CheckInValue) -> String {
        switch choice {
        case .automatic: "Automatic"
        case .state(.ungraded): "— Ungraded"
        case .state(.exempt): "Exempt"
        case .points(let points): "\(points)/5"
        }
    }
}
