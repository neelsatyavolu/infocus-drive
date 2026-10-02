import SwiftUI

/// The unsaved Final Cut, feedback and turned-in date of one row.
struct GradeDraft: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case score = "Score", ungraded = "Ungraded", exempt = "Exempt"
        var id: String { rawValue }
    }

    var mode: Mode = .ungraded
    var finalCutText = ""
    var feedback = ""
    var turnedIn = false
    var turnedInDate = Date()

    init() {}

    init(_ row: CycleGradeRow) {
        if row.finalCutState == .exempt {
            mode = .exempt
        } else if row.effortPoints != nil {
            mode = .score
            finalCutText = GradeEditorLogic.finalCutText(row)
        }
        feedback = row.feedback
        if let key = row.turnedInDate, let date = GradeEditorLogic.date(fromKey: key) {
            turnedIn = true
            turnedInDate = date
        }
    }

    /// What Save sends; nil when Score has no valid number.
    var finalCutInput: GradeEditorLogic.FinalCutInput? {
        switch mode {
        case .ungraded: return .state(.ungraded)
        case .exempt: return .state(.exempt)
        case .score:
            if case .points(let points)? = GradeEditorLogic.parseFinalCut(finalCutText) { return .points(points) }
            return nil
        }
    }

    var turnedInKey: String? { turnedIn ? GradeEditorLogic.dateKey(turnedInDate) : nil }

    static func == (lhs: GradeDraft, rhs: GradeDraft) -> Bool {
        lhs.mode == rhs.mode
            && (lhs.mode != .score || lhs.finalCutInput == rhs.finalCutInput)
            && lhs.feedback == rhs.feedback
            && lhs.turnedInKey == rhs.turnedInKey
    }
}

/// Final Cut score, turned-in date and feedback for one person.
struct FinalCutEditor: View {
    @Binding var draft: GradeDraft
    let row: CycleGradeRow
    let finalCutDate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Final Cut")
            Picker("Final Cut", selection: $draft.mode) {
                ForEach(GradeDraft.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if draft.mode == .score {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("0–50", text: $draft.finalCutText)
                        .keyboardType(.decimalPad)
                        .font(.mono(28, .medium))
                        .frame(width: 110)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 52)
                        .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(scoreBorder))
                        .accessibilityLabel("Final Cut points out of 50")
                    Text("/ 50").font(.mono(16)).foregroundStyle(Brand.muted)
                }
                if draft.finalCutInput == nil {
                    Label("Enter a number from 0 to 50.", systemImage: "exclamationmark.circle")
                        .font(.small).foregroundStyle(Brand.danger)
                } else if row.extensionDetails.map({ $0.chargedDays > 0 }) == true {
                    Text("A late penalty may apply to what the student is awarded. The Portal works it out from the turned-in date.")
                        .font(.small).foregroundStyle(Brand.muted)
                }
            }

            Divider().overlay(Brand.line)
            turnedIn
            Divider().overlay(Brand.line)
            feedback
        }
        .card()
    }

    private var scoreBorder: Color { draft.finalCutInput == nil ? Brand.danger : Brand.control }

    @ViewBuilder private var turnedIn: some View {
        Toggle("Turned in", isOn: $draft.turnedIn)
            .font(.bodyText)
            .tint(Brand.fill)
            .disabled(finalCutDate == nil)
        if finalCutDate == nil {
            Text("Set this cycle's Final Cut date in Package Cycles before entering Turned in.")
                .font(.small).foregroundStyle(Brand.warning)
        } else if draft.turnedIn {
            DatePicker("Date", selection: $draft.turnedInDate, displayedComponents: .date)
                .font(.bodyText)
                .environment(\.timeZone, GradeEditorLogic.pacific)
        }
        if let details = row.extensionDetails, details.calculatedDays > 0 || details.exempt {
            Text(extensionText(details)).font(.small).foregroundStyle(Brand.secondary)
        }
        if let remaining = row.extensionsRemaining {
            Text("Extension days left this year: \(GradeEditorLogic.points(remaining))")
                .font(.small).foregroundStyle(Brand.muted)
        }
    }

    private func extensionText(_ details: ExtensionDetails) -> String {
        if details.exempt { return "Extension exempt." }
        return "\(GradeEditorLogic.points(details.calculatedDays)) days after the Final Cut date; \(GradeEditorLogic.points(details.chargedDays)) charged, \(GradeEditorLogic.points(details.freeDays)) free."
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Feedback").font(.bodyText)
                Spacer()
                Text("\(draft.feedback.count)/\(GradeEditorLogic.maxFeedback)")
                    .font(.mono(12))
                    .foregroundStyle(draft.feedback.count > GradeEditorLogic.maxFeedback ? Brand.danger : Brand.muted)
            }
            TextEditor(text: $draft.feedback)
                .font(.bodyText)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
                .accessibilityLabel("Feedback for the student")
        }
    }
}
