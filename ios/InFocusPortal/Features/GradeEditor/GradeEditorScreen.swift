import SwiftUI

/// The Grade Editor: the web's Cycle and Total views, the Missing grades list,
/// and Participation entry, each from the same Portal endpoints.
struct GradeEditorScreen: View {
    enum Mode: String, CaseIterable, Identifiable {
        case cycle = "Cycle", totals = "Totals", missing = "Missing", participation = "Participation"
        var id: String { rawValue }
    }

    @State private var mode: Mode = Self.initialMode
    @Environment(Router.self) private var router

    /// DEBUG: `-InFocusGradeEditorMode totals|missing|participation` opens on that view (screenshots).
    private static var initialMode: Mode {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "InFocusGradeEditorMode"),
           let mode = Mode.allCases.first(where: { $0.rawValue.lowercased() == raw }) { return mode }
        #endif
        return .cycle
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Grade Editor view", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Brand.gutter)
            .padding(.vertical, 8)

            switch mode {
            case .cycle: CycleGradesView()
            case .totals: GradeTotalsView()
            case .missing: MissingGradesView()
            case .participation: ParticipationEntryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandBackground()
        .navigationTitle("Grade Editor")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        // `-InFocusGradeEditorStudent <userId>` opens that person's cycle 2 grade (screenshots).
        .task {
            if let userId = UserDefaults.standard.string(forKey: "InFocusGradeEditorStudent") {
                router.push(.gradeEditor(.cycleStudent(cycle: 2, userId: userId)))
            }
        }
        #endif
    }
}
