import SwiftUI

/// Extra equipment managers. Producers appoint and remove them; appointed managers see the list.
struct GearManagersView: View {
    let model: EquipmentModel
    @Environment(SessionStore.self) private var session
    @State private var picking = false
    @State private var removing: ManagerRow?

    /// The web's rule: any platform role (associate producer and up) appoints.
    private var canAppoint: Bool { session.user?.isProducer == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Producers appoint extra managers. Appointed managers can run inventory and requests but can't appoint others.")
                    .font(.small).foregroundStyle(Brand.secondary)
                LoadableView(model.managers, retry: { Task { await model.loadManagers() } }) { managers in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Extra managers")
                        if managers.isEmpty {
                            Text("No extra managers yet.").font(.small).foregroundStyle(Brand.muted)
                        }
                        ForEach(managers) { row in
                            HStack(spacing: 12) {
                                Avatar(name: row.label, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.label).font(.bodyText).foregroundStyle(Brand.foreground)
                                    Text("Added \(FeatureDates.shortDay(row.createdAt))").font(.small).foregroundStyle(Brand.muted)
                                }
                                Spacer(minLength: 8)
                                if canAppoint {
                                    Button("Remove") { removing = row }
                                        .font(.lexend(14, .medium, relativeTo: .subheadline))
                                        .foregroundStyle(Brand.danger)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .disabled(model.busy != nil)
                                        .accessibilityLabel("Remove \(row.label)")
                                }
                            }
                            .card(padding: 12)
                            .overlay { if model.busy == row.id { ProgressView() } }
                        }
                        if canAppoint {
                            Button { picking = true } label: { Label("Add a manager", systemImage: "person.badge.plus") }
                                .buttonStyle(.brandSecondary)
                                .padding(.top, 4)
                        } else {
                            Text("Only producers appoint managers.").font(.small).foregroundStyle(Brand.muted)
                        }
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.loadManagers() }
        .task { await model.loadManagers() }
        .sheet(isPresented: $picking) {
            PersonPickerSheet(title: "Add a manager", members: model.members,
                              excluded: Set(model.managers.value?.map(\.userId) ?? []),
                              retry: { Task { await model.loadMembers() } }) { member in
                Task { await model.addManager(member) }
            }
            .task { await model.loadMembers() }
        }
        .confirmationDialog("Remove this manager?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { row in
            Button("Remove \(row.label)", role: .destructive) { Task { await model.removeManager(row) } }
        } message: { _ in
            Text("They lose access to Manage. Producers keep theirs.")
        }
    }
}
