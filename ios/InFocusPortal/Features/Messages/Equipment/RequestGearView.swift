import SwiftUI

/// Pick available gear, then send one request (managers approve it and hold the items).
struct RequestGearView: View {
    @Bindable var model: EquipmentModel
    let done: () -> Void
    @State private var reviewing = false

    var body: some View {
        LoadableView(model.available, retry: { Task { await model.loadAvailable() } }) { items in
            List {
                if items.isEmpty {
                    EmptyStateView(title: "Everything's out", message: "No gear is free right now. Check back later.")
                        .listRowBackground(Color.clear)
                }
                ForEach(model.matchingGear) { item in
                    Button { model.toggle(item) } label: {
                        let picked = model.selected.contains(item.barcode)
                        GearRow(item: item) {
                            Image(systemName: picked ? "checkmark.square.fill" : "square")
                                .font(.system(size: 22))
                                .foregroundStyle(picked ? Brand.green : Brand.control)
                        }
                        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: Brand.gutter, bottom: 4, trailing: Brand.gutter))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search gear or code")
            .overlay {
                if !items.isEmpty && model.matchingGear.isEmpty { ContentUnavailableView.search(text: model.query) }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.selected.isEmpty {
                    Button("Request \(model.selected.count) item\(model.selected.count == 1 ? "" : "s")") { reviewing = true }
                        .buttonStyle(.brandPrimary)
                        .padding(Brand.gutter)
                        .background(Brand.background)
                }
            }
        }
        .refreshable { await model.loadAvailable() }
        .task { if model.available.value == nil { await model.loadAvailable() } }
        .sheet(isPresented: $reviewing) {
            GearRequestForm(model: model) {
                reviewing = false
                done()
            }
        }
    }
}

/// Who's asking: name and email from the Portal, student ID remembered on this iPhone.
private struct GearRequestForm: View {
    let model: EquipmentModel
    let sent: () -> Void
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("equipment.studentId") private var studentId = ""
    @State private var name = ""
    @State private var email = ""

    private var ready: Bool {
        ![name, studentId, email].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty } && !model.selectedGear.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.selectedGear) { item in
                        HStack {
                            Text(item.name).font(.bodyText)
                            Spacer()
                            Text(item.barcode).font(.mono(12)).foregroundStyle(Brand.muted)
                        }
                    }
                } header: { Text("Requesting") }
                Section {
                    TextField("Full name", text: $name).textContentType(.name)
                    TextField("Student ID", text: $studentId).keyboardType(.numberPad)
                    TextField("School email", text: $email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("You")
                } footer: {
                    Text("Equipment managers get an email. When they approve it, the items are held for you until you check them out.")
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Request gear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.busy == "request" {
                        ProgressView()
                    } else {
                        Button("Send") {
                            Task { if await model.submitRequest(name: name, studentId: studentId, email: email) { sent() } }
                        }
                        .disabled(!ready)
                    }
                }
            }
            .onAppear {
                if name.isEmpty { name = session.user?.name ?? "" }
                if email.isEmpty { email = session.user?.email ?? "" }
            }
        }
    }
}
