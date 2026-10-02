import SwiftUI

/// Pick another show date for a package. Shows that already hold
/// two packages can't be picked (the Portal refuses a third).
struct MoveShowSheet: View {
    let package: QueuePackage
    let model: PublishingModel
    let service: PublishingService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.moveChoices) { show in
                        row(show)
                    }
                } footer: {
                    Text("Up to \(QueueLogic.maxPerShow) packages per show.").font(.small)
                }
            }
            .font(.bodyText)
            .scrollContentBackground(.hidden)
            .brandBackground()
            .navigationTitle("Move \(package.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .disabled(model.busyRowId == package.id)
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ show: UpcomingShow) -> some View {
        let packages = model.payload?.packages ?? []
        let current = package.queuedForShowDate == show.date
        let count = QueueLogic.occupied(on: show.date, in: packages, excluding: package.id)
        let full = !QueueLogic.canPlace(on: show.date, in: packages, moving: package.id)
        return Button {
            Task {
                if await model.move(package, to: show.date, service: service) { dismiss() }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(show.label).foregroundStyle(full ? Brand.muted : Brand.foreground)
                    Text(full ? "Full" : "\(count) of \(QueueLogic.maxPerShow) taken")
                        .font(.small)
                        .foregroundStyle(Brand.muted)
                }
                Spacer()
                if current {
                    Image(systemName: "checkmark").foregroundStyle(Brand.green).accessibilityLabel("Current show")
                } else if model.busyRowId == package.id {
                    ProgressView()
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(full || current)
        .accessibilityHint(full ? "This show already has \(QueueLogic.maxPerShow) packages." : "")
    }
}
