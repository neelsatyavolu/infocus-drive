import SwiftUI

/// Class Board settings: which cycle it shows (Admin → Package Cycles on the web; producers see it,
/// executives change it). The PIN that opens the board signed out is in Settings → PINs, as on the web.
struct ClassBoardSettingsSheet: View {
    @Environment(\.portalClient) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var model = ClassBoardSettingsModel()

    var body: some View {
        NavigationStack {
            Form {
                cycleSection
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Board settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await model.load(api: api) }
            .refreshable { await model.load(api: api) }
            .alert("Couldn't save", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
        }
    }

    private var api: CommunityAPI { CommunityAPI.current(client) }

    @ViewBuilder
    private var cycleSection: some View {
        Section {
            switch model.cycle {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 44)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Brand.danger)
                Button("Try again") { Task { await model.load(api: api) } }
            case .loaded(let setting):
                Picker("Shows", selection: cycleBinding(setting)) {
                    Text("Current cycle (automatic)").tag(Int?.none)
                    ForEach(setting.cycles) { Text($0.label).tag(Optional($0.cycleNumber)) }
                }
                .disabled(!setting.canEdit || model.savingCycle)
                if model.savingCycle {
                    Text("Saving…").font(.small).foregroundStyle(Brand.muted)
                } else if let notice = model.notice {
                    Label(notice, systemImage: "checkmark").font(.small).foregroundStyle(Brand.green)
                }
            }
        } header: {
            Text("Class Board cycle")
        } footer: {
            Text(model.cycle.value?.canEdit == false
                 ? "Which cycle's packages the board shows. Executive producers can change it."
                 : "Which cycle's packages the board shows. Current cycle moves on after each Final Cut deadline.")
        }
    }

    private func cycleBinding(_ setting: ClassBoardCycleSetting) -> Binding<Int?> {
        Binding(get: { model.cycle.value?.cycleNumber ?? setting.cycleNumber },
                set: { number in Task { await model.setCycle(number, api: api) } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}
