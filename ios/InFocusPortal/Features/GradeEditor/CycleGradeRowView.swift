import SwiftUI

/// One person in the cycle list: name, the four check-ins, Final Cut and status.
struct CycleGradeRowView: View {
    let row: CycleGradeRow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName).font(.lexend(16, .semibold, relativeTo: .headline))
                    if let email = row.email {
                        Text(email.split(separator: "@").first.map(String.init) ?? email)
                            .font(.mono(12))
                            .foregroundStyle(Brand.muted)
                    }
                }
                Spacer()
                GradeStatusTag(row: row)
            }
            HStack(alignment: .bottom) {
                CheckInStrip(scores: row.checkInScores)
                Spacer()
                FinalCutScore(row: row)
            }
        }
        .card(padding: 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this person's grade")
    }
}

struct GradeStatusTag: View {
    let row: CycleGradeRow

    var body: some View {
        let status = GradeEditorLogic.status(row)
        StatusTag(text: status.label, tone: status == .published ? .success : status == .revised ? .warning : .neutral)
    }
}

/// "PITCH 5 · POC 5 · A/B 4 · IC —": released check-ins, N/A when not released yet.
struct CheckInStrip: View {
    let scores: CheckInScores?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(CheckInStage.allCases) { stage in
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortLabel(stage))
                        .font(.lexend(10, .medium, relativeTo: .caption2))
                        .tracking(1)
                        .foregroundStyle(Brand.muted)
                    Text(value(stage))
                        .font(.mono(13, .medium))
                        .foregroundStyle(scores?[stage] == nil ? Brand.muted : Brand.foreground)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(stage.label) \(scores?[stage]?.label ?? "not released")")
            }
        }
    }

    private func value(_ stage: CheckInStage) -> String {
        guard let value = scores?[stage] else { return "N/A" }
        if case .points(let points) = value { return "\(points)" }
        return value == .state(.exempt) ? "EX" : "—"
    }

    private func shortLabel(_ stage: CheckInStage) -> String {
        switch stage {
        case .pitching: "PITCH"
        case .proofOfContact: "POC"
        case .aRollBRoll: "A/B"
        case .initialCut: "IC"
        }
    }
}

/// "46/50" and its percent, "Exempt", or "—/50".
struct FinalCutScore: View {
    let row: CycleGradeRow

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if row.finalCutState == .exempt {
                Text("Exempt").font(.lexend(15, .semibold, relativeTo: .headline))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(GradeEditorLogic.points(row.effortPoints)).font(.mono(20, .medium))
                    Text("/50").font(.mono(12)).foregroundStyle(Brand.muted)
                }
                Text(GradeEditorLogic.percent(row.percentage))
                    .font(.mono(12))
                    .foregroundStyle((row.percentage ?? 0) >= 80 ? Brand.green : Brand.warning)
                    .opacity(row.percentage == nil ? 0 : 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.finalCutState == .exempt ? "Final Cut exempt"
                            : "Final Cut \(GradeEditorLogic.points(row.effortPoints)) of 50")
    }
}
