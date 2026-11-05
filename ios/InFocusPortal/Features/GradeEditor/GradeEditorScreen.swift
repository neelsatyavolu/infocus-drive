import SwiftUI

/// The Grade Editor: the web's Cycle and Total views, the Missing grades list,
/// and Participation entry, each from the same Portal endpoints.
struct GradeEditorScreen: View {
    enum Mode: String, CaseIterable, Identifiable {
        case cycle = "Cycle", totals = "Totals", missing = "Missing", participation = "Participation"
        var id: String { rawValue }
    }

    @State private var mode: Mode
    /// Participation has scores that aren't saved yet: leaving that view asks first (like the web).
    @State private var participationUnsaved = false
    /// The view the person picked while Participation had unsaved scores.
    @State private var leavingTo: Mode?
    @Environment(Router.self) private var router

    /// `mode`: the view to open on (`/grade-editor?view=participation`); nil opens Cycle.
    init(mode: Mode? = nil) {
        _mode = State(initialValue: mode ?? Self.initialMode)
    }

    /// DEBUG: `-InFocusGradeEditorMode totals|missing|participation` opens on that view (screenshots).
    private static var initialMode: Mode {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "InFocusGradeEditorMode"),
           let mode = Mode.allCases.first(where: { $0.rawValue.lowercased() == raw }) { return mode }
        #endif
        return .cycle
    }

    /// Switching views; leaving Participation with unsaved scores asks first.
    private var modeSelection: Binding<Mode> {
        Binding {
            mode
        } set: { next in
            if mode == .participation, next != .participation, participationUnsaved {
                leavingTo = next
            } else {
                mode = next
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Grade Editor view", selection: modeSelection) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Brand.gutter)
            .padding(.vertical, 8)

            switch mode {
            case .cycle: CycleGradesView()
            case .totals: GradeTotalsView()
            case .missing: MissingGradesView()
            case .participation: ParticipationEntryView(unsaved: $participationUnsaved)
            }
        }
        .confirmationDialog("Discard unsaved scores?",
                            isPresented: Binding(get: { leavingTo != nil }, set: { if !$0 { leavingTo = nil } }),
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                if let next = leavingTo { participationUnsaved = false; mode = next }
                leavingTo = nil
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
