import SwiftUI

/// Livestream managers: add or edit an event (the web's event editor), including its crew and
/// each crew member's credit hours, and delete it.
struct LivestreamEditorSheet: View {
    let model: LivestreamsModel
    /// nil adds a new event.
    let event: LivestreamEvent?
    var onDeleted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var form: LivestreamEventForm
    @State private var errors = LivestreamEventForm.Errors()
    @State private var picker: Picker?
    @State private var confirmingDelete = false

    private enum Picker: String, Identifiable {
        case crew, manager
        var id: String { rawValue }
    }

    init(model: LivestreamsModel, event: LivestreamEvent?, defaultCapacity: Int = 4, complete: Bool = false,
         onDeleted: @escaping () -> Void = {}) {
        self.model = model
        self.event = event
        self.onDeleted = onDeleted
        _form = State(initialValue: event.map { LivestreamEventForm(event: $0, complete: complete) }
            ?? LivestreamEventForm(capacity: defaultCapacity))
    }

    var body: some View {
        NavigationStack {
            Form {
                details
                when
                credit
                crewSection
                Section("Notes") {
                    TextField("Setup, parking, who to ask for…", text: $form.notes, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: form.notes) { _, value in
                            if value.count > LivestreamEventForm.notesLimit { form.notes = String(value.prefix(LivestreamEventForm.notesLimit)) }
                        }
                }
                if let event {
                    Section {
                        Button("Delete livestream") { confirmingDelete = true }
                            .buttonStyle(QuietDestructiveButtonStyle())
                            .disabled(model.busy != nil)
                            .listRowBackground(Color.clear)
                    } footer: {
                        Text("Removes \(event.title), its crew and its sign-up requests.")
                    }
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .environment(\.timeZone, FeatureDates.timeZone)
            .navigationTitle(event == nil ? "New livestream" : "Edit livestream")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.busy != nil {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                    }
                }
            }
            .sheet(item: $picker) { kind in
                PersonPickerSheet(title: kind == .crew ? "Add crew" : "Livestream manager", members: model.members,
                                  excluded: kind == .crew ? Set(form.crew.map(\.id)) : [],
                                  retry: { Task { await model.loadMembers() } }) { member in
                    let person = LivestreamPerson(id: member.id, name: member.label, email: member.email)
                    if kind == .crew { form.add(person) } else { form.manager = person }
                }
                .task { await model.loadMembers() }
            }
            .livestreamAlerts(model)
            .confirmationDialog("Delete this livestream?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let event else { return }
                    Task {
                        if await model.delete(event) {
                            dismiss()
                            onDeleted()
                        }
                    }
                }
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    private var details: some View {
        Section {
            TextField("Title (e.g. Varsity Football vs Gunn)", text: $form.title)
            error(.title)
            TextField("Location", text: $form.location)
            SwiftUI.Picker("Status", selection: $form.status) {
                ForEach(LivestreamEvent.Status.allCases, id: \.self) { Text(Self.word($0)).tag($0) }
            }
            SwiftUI.Picker("Availability", selection: $form.availability) {
                ForEach(LivestreamEvent.Availability.allCases, id: \.self) { Text(LivestreamTags.availability($0)).tag($0) }
            }
            Button {
                picker = .manager
            } label: {
                LabeledContent("Manager", value: form.manager?.label ?? "None")
            }
            .foregroundStyle(Brand.foreground)
            if form.manager != nil {
                Button("Remove manager", role: .destructive) { form.manager = nil }
            }
        }
    }

    private var when: some View {
        Section {
            DatePicker("Starts", selection: $form.startsAt)
            DatePicker("Crew arrives", selection: $form.arrivesAt, displayedComponents: .hourAndMinute)
        } header: {
            Text("When")
        } footer: {
            Text("Pacific time. The crew arrives on the same day the event starts.")
        }
    }

    private var credit: some View {
        Section {
            LabeledContent("Hours") {
                TextField("e.g. 2.5", text: $form.hours).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            error(.hours)
            error(.completedHours)
            LabeledContent("Crew size") {
                TextField("4", text: $form.capacity).keyboardType(.numberPad).multilineTextAlignment(.trailing)
            }
            error(.capacity)
        } header: {
            Text("Credit")
        } footer: {
            Text("Each crew member gets these hours once the livestream is marked Completed, unless you set their own below.")
        }
    }

    private var crewSection: some View {
        Section {
            ForEach(form.crew, id: \.id) { person in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(person.label)
                        Spacer()
                        TextField("Hours", text: Binding(get: { form.credits[person.id] ?? "" },
                                                         set: { form.credits[person.id] = $0 }))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .accessibilityLabel("Credit hours for \(person.label)")
                    }
                    if errors.credits.contains(person.id) {
                        Text(LivestreamEventForm.creditError).font(.small).foregroundStyle(Brand.danger)
                    }
                }
            }
            .onDelete { offsets in
                for id in offsets.map({ form.crew[$0].id }) { form.remove(id) }
            }
            Button { picker = .crew } label: { Label("Add crew", systemImage: "person.badge.plus") }
        } header: {
            Text("Crew (\(form.crew.count))")
        } footer: {
            Text("Leave a crew member's hours blank to give them the event's hours. Swipe to remove someone.")
        }
    }

    @ViewBuilder
    private func error(_ field: LivestreamEventForm.Field) -> some View {
        if let message = errors.fields[field] {
            Text(message).font(.small).foregroundStyle(Brand.danger)
        }
    }

    private func save() {
        errors = form.validate()
        guard errors.isEmpty else { return }
        Task { if await model.save(form, event: event) { dismiss() } }
    }

    static func word(_ status: LivestreamEvent.Status) -> String {
        switch status {
        case .scheduled: "Scheduled"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }
}
