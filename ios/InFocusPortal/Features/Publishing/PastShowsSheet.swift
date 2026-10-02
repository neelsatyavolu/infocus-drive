import SwiftUI

/// Shows whose air date has passed but still hold packages, newest first.
/// Producers can still move, download or remove them here (like the web's
/// Past shows dialog); the live queue only lists today and later.
struct PastShowsSheet: View {
    let model: PublishingModel
    let service: PublishingService
    let download: (QueuePackage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var moving: QueuePackage?
    @State private var removing: QueuePackage?

    var body: some View {
        NavigationStack {
            Group {
                if model.past.isEmpty {
                    EmptyStateView(title: "No past shows yet",
                                   message: "Shows leave the queue once their day has passed.")
                } else {
                    list
                }
            }
            .brandBackground()
            .navigationTitle("Past shows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $moving) { MoveShowSheet(package: $0, model: model, service: service) }
            .confirmationDialog("Remove from the queue?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible, presenting: removing) { package in
                Button("Remove \(package.title)", role: .destructive) {
                    Task { await model.remove(package, service: service) }
                }
            }
            .publishingAlerts(model)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(model.past) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        QueueShowHeader(label: QueueLogic.showLabel(section.date), count: section.packages.count)
                        ForEach(section.packages) { package in
                            QueuePackageRow(package: package, busy: model.busyRowId == package.id,
                                            actions: model.canEdit ? actions : nil)
                                .card(padding: 12)
                        }
                    }
                }
            }
            .padding(Brand.gutter)
        }
    }

    private var actions: QueueRowActions {
        QueueRowActions(move: { moving = $0 },
                        download: { package in dismiss(); download(package) },
                        remove: { removing = $0 })
    }
}
