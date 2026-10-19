import SwiftUI

/// Inventory (managers): add an item, find one, rename or recode it, archive what's in.
struct InventoryView: View {
    @Bindable var model: EquipmentModel
    @State private var query = ""
    @State private var adding = false
    @State private var editing: ManagedOut.Item?
    @State private var archiving: ManagedOut.Item?

    var body: some View {
        ScrollView {
            LoadableView(model.inventory, retry: { Task { await model.loadInventory() } }) { items in
                let shown = EquipmentModel.searchItems(items, query: query)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Filter by name or code", text: $query)
                            .font(.bodyText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                            .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
                        Button { adding = true } label: { Label("Add", systemImage: "plus") }
                            .buttonStyle(.brandPrimary)
                            .fixedSize()
                    }
                    Text(countLine(shown: shown.count, total: items.count))
                        .font(.small).foregroundStyle(Brand.muted)
                    if items.isEmpty {
                        EmptyStateView(title: "No items yet", message: "Add your first item.", actionTitle: "Add item") { adding = true }
                    } else if shown.isEmpty {
                        EmptyStateView(title: "No items match “\(query)”", message: "Try another name or code.",
                                       actionTitle: "Clear filter") { query = "" }
                    }
                    ForEach(shown) { item in
                        InventoryRow(item: item, busy: model.busy != nil) {
                            editing = item
                        } archive: {
                            archiving = item
                        }
                        .overlay { if model.busy == item.id { ProgressView() } }
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.loadInventory() }
        .task { await model.loadInventory() }
        .sheet(isPresented: $adding) {
            GearItemForm(title: "Add item", model: model) { name, code in
                await model.addItem(name: name, barcode: code)
            }
        }
        .sheet(item: $editing) { item in
            GearItemForm(title: "Edit item", name: item.name, barcode: item.barcode, model: model) { name, code in
                await model.saveItem(item, name: name, barcode: code)
            }
        }
        .confirmationDialog("Archive this item?", isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } }),
                            titleVisibility: .visible, presenting: archiving) { item in
            Button("Archive \(item.name)", role: .destructive) { Task { await model.archive(item) } }
        } message: { _ in
            Text("It leaves the inventory and can't be requested or checked out. Its code becomes free to reuse.")
        }
    }

    private func countLine(shown: Int, total: Int) -> String {
        let count = query.trimmingCharacters(in: .whitespaces).isEmpty ? "\(total)" : "\(shown) of \(total)"
        return "\(count) \(total == 1 ? "item" : "items") · Archive only when the item is in (not out or held)."
    }
}

private struct InventoryRow: View {
    let item: ManagedOut.Item
    let busy: Bool
    let edit: () -> Void
    let archive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GearRow(item: GearItem(id: item.id, name: item.name, barcode: item.barcode)) {
                Menu {
                    Button("Edit", systemImage: "pencil", action: edit)
                    Button("Archive", systemImage: "archivebox", role: .destructive, action: archive)
                        .disabled(item.state != .in)
                } label: {
                    HStack(spacing: 6) {
                        StatusTag(text: label, tone: tone)
                        Image(systemName: "ellipsis").foregroundStyle(Brand.muted)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(busy)
                .accessibilityLabel("\(label). Actions for \(item.name)")
            }
            if let who = holder {
                Text(who).font(.small).foregroundStyle(Brand.secondary).padding(.horizontal, 4)
            }
        }
    }

    private var label: String {
        if item.isOverdue() { return "Overdue" }
        switch item.state {
        case .in: return "In"
        case .out: return "Out"
        case .held: return "Held"
        }
    }

    private var tone: StatusTag.Tone {
        if item.isOverdue() { return .danger }
        switch item.state {
        case .in: return .success
        case .out: return .neutral
        case .held: return .warning
        }
    }

    private var holder: String? {
        switch item.state {
        case .out: item.checkedOutBy.map { "Out to \($0.label)" }
        case .held: item.onHoldForStudent.map { "Held for \($0.label)" }
        case .in: nil
        }
    }
}

/// Name and code for a new or edited item.
private struct GearItemForm: View {
    let title: String
    @State var name = ""
    @State var barcode = ""
    let model: EquipmentModel
    let save: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, name: String = "", barcode: String = "", model: EquipmentModel,
         save: @escaping (String, String) async -> Bool) {
        self.title = title
        _name = State(initialValue: name)
        _barcode = State(initialValue: barcode)
        self.model = model
        self.save = save
    }

    private var ready: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !barcode.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Canon T8i)", text: $name)
                    TextField("Code", text: $barcode)
                        .font(.mono(15))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The code is the label the checkout station scans. Each item needs its own.")
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.busy != nil {
                        ProgressView()
                    } else {
                        Button("Save") { Task { if await save(name, barcode) { dismiss() } } }
                            .disabled(!ready)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
