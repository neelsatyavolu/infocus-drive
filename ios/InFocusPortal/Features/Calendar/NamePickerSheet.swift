import SwiftUI

/// Picks one person for a calendar job. Names that can't take it stay visible but greyed
/// with the reason, so nobody wonders where a classmate went. "Nobody" clears the slot.
struct NamePickerSheet: View {
    let title: String
    let names: [String]
    let current: String
    var allowsNobody = true
    let block: (String) -> CastEligibility.Block?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if allowsNobody && query.isEmpty && !current.isEmpty {
                    Button(role: .destructive) { pick("") } label: {
                        Label("Nobody", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
                ForEach(filtered, id: \.self) { name in
                    row(name, blocked: block(name))
                }
                if filtered.isEmpty {
                    Text("No one matches “\(query)”.").font(.small).foregroundStyle(Brand.muted)
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search names")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    @ViewBuilder
    private func row(_ name: String, blocked: CastEligibility.Block?) -> some View {
        let selected = name.caseInsensitiveCompare(current) == .orderedSame
        Button { pick(name) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(blocked == nil || selected ? Brand.foreground : Brand.muted)
                    if let blocked, !selected {
                        Text(blocked.reason).font(.small).foregroundStyle(Brand.muted)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Brand.green).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .disabled(blocked != nil && !selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(blocked.map { $0.reason } ?? "")
    }

    private func pick(_ name: String) {
        dismiss()
        if name.caseInsensitiveCompare(current) != .orderedSame { onPick(name) }
    }
}

/// What a picker sheet is open for.
struct NamePickerRequest: Identifiable {
    let id = UUID()
    let title: String
    let names: [String]
    let current: String
    var allowsNobody = true
    let block: (String) -> CastEligibility.Block?
    let onPick: (String) -> Void
}

extension View {
    func namePicker(_ request: Binding<NamePickerRequest?>) -> some View {
        sheet(item: request) { request in
            NamePickerSheet(title: request.title, names: request.names, current: request.current,
                            allowsNobody: request.allowsNobody, block: request.block, onPick: request.onPick)
                .presentationDetents([.medium, .large])
        }
    }
}
