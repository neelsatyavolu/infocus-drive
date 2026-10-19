import SwiftUI

/// Producers appoint and remove livestream managers. Managers can edit the schedule, approve
/// sign-ups and see completion; they can't sign up for crews themselves.
struct LivestreamManagersSheet: View {
    let model: LivestreamsModel
    let canAppoint: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var removing: LivestreamPerson?

    private var managers: [LivestreamPerson] { model.state.value?.managers ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if managers.isEmpty {
                        Text("No managers yet.").foregroundStyle(Brand.muted)
                    }
                    ForEach(managers, id: \.id) { person in
                        HStack(spacing: 12) {
                            Avatar(name: person.label, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(person.label).font(.bodyText)
                                if let email = person.email { Text(email).font(.small).foregroundStyle(Brand.muted) }
                            }
                            Spacer(minLength: 8)
                            if canAppoint {
                                Button("Remove") { removing = person }
                                    .font(.lexend(14, .medium, relativeTo: .subheadline))
                                    .foregroundStyle(Brand.danger)
                                    .buttonStyle(.borderless)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .disabled(model.busy != nil)
                                    .accessibilityLabel("Remove \(person.label)")
                            }
                        }
                        .listRowBackground(Brand.card)
                    }
                } footer: {
                    Text("Producers appoint managers. Managers can edit the schedule, approve sign-ups, and view completion.")
                }
                if canAppoint {
                    Section {
                        Button { picking = true } label: { Label("Add a manager", systemImage: "person.badge.plus") }
                            .listRowBackground(Brand.card)
                    }
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Livestream managers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .livestreamAlerts(model)
            .sheet(isPresented: $picking) {
                PersonPickerSheet(title: "Add a manager", members: model.members, excluded: Set(managers.map(\.id)),
                                  retry: { Task { await model.loadMembers() } }) { member in
                    Task { await model.addManager(member) }
                }
                .task { await model.loadMembers() }
            }
            .confirmationDialog("Remove this manager?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { person in
                Button("Remove \(person.label)", role: .destructive) { Task { await model.removeManager(person) } }
            } message: { _ in
                Text("They go back to signing up for crews like everyone else.")
            }
        }
    }
}
