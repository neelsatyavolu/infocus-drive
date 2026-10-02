import SwiftUI

/// Package Cycles (More → Producer tools): the roster (`/package-progress`, producers) and the
/// cycle dates with Package of the Cycle winners (`/package-cycles`, everyone).
struct PackageCyclesHome: View {
    enum Section: String, Hashable { case roster, dates }

    /// A cycle to open the roster on (`/package-progress?cycle=N`); nil picks the active one.
    var cycle: Int?

    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @State private var section: Section?
    @State private var roster: RosterStore?
    @State private var cycles: CyclesStore?

    private var isProducer: Bool { session.user?.isProducer ?? false }
    private var shown: Section { isProducer ? (section ?? .roster) : .dates }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isProducer {
                    Picker("Show", selection: Binding(get: { shown }, set: { section = $0 })) {
                        Text("Roster").tag(Section.roster)
                        Text("Dates & winners").tag(Section.dates)
                    }
                    .pickerStyle(.segmented)
                }
                switch shown {
                case .roster:
                    if let roster { RosterView(store: roster) } else { SkeletonList() }
                case .dates:
                    if let cycles { CyclesView(store: cycles) } else { SkeletonList() }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await reload() }
        .brandBackground()
        .navigationTitle("Package Cycles")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: shown) { await reload() }
    }

    private func reload() async {
        let service = PackageCyclesService.resolve(client)
        switch shown {
        case .roster:
            let store = roster ?? RosterStore(service: service, cycle: cycle)
            roster = store
            await store.load()
            #if DEBUG
            openDebugGroup(store)
            #endif
        case .dates:
            let store = cycles ?? CyclesStore(service: service)
            cycles = store
            await store.load()
        }
    }

    #if DEBUG
    @MainActor private static var debugOpened = false

    /// `-InFocusCyclesGroup <rowId>` opens a group once (screenshots); `-InFocusCyclesSection dates`.
    private func openDebugGroup(_ store: RosterStore) {
        guard !Self.debugOpened else { return }
        Self.debugOpened = true
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "InFocusCyclesSection") == "dates" {
            section = .dates
        } else if let id = defaults.string(forKey: "InFocusCyclesGroup"), let cycle = store.cycle {
            router.push(.packageCycles(.group(rowId: id, cycle: cycle)))
        }
    }
    #endif
}
