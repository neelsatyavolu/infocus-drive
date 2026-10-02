import SwiftUI

/// The Publishing Queue (More → Producer tools): today's and upcoming shows,
/// each with up to two packages and their YouTube status. Producers move,
/// add, download and remove packages; website managers read it.
struct PublishingScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var model = PublishingModel()
    @State private var moving: QueuePackage?
    @State private var removing: QueuePackage?
    @State private var showAdd = false
    @State private var showPast = false

    private var service: PublishingService { PublishingService(client: client) }

    var body: some View {
        LoadableView(model.state, retry: { Task { await model.load(service) } }) { payload in
            list(payload)
        }
        .brandBackground()
        .navigationTitle("Publishing Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $moving) { package in
            MoveShowSheet(package: package, model: model, service: service)
        }
        .sheet(isPresented: $showAdd, onDismiss: { Task { await model.load(service) } }) {
            AddPackageSheet(model: model, service: service)
        }
        .sheet(isPresented: $showPast) {
            PastShowsSheet(model: model, service: service, download: download)
        }
        .confirmationDialog("Remove from the queue?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { package in
            Button("Remove \(package.title)", role: .destructive) {
                Task { await model.remove(package, service: service) }
            }
        } message: { _ in
            Text("Its show date opens up. Anything already sent to YouTube stays there.")
        }
        .publishingAlerts(model)
        .task { await model.load(service) }
    }

    private func list(_ payload: QueuePayload) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Nameplate(eyebrow: payload.canEdit ? "Producers" : "Website managers", title: "Publishing Queue",
                          subtitle: payload.canEdit ? "Up to \(QueueLogic.maxPerShow) packages per show" : "Read only")
                if payload.canEdit {
                    Text("New packages land on the next empty show. Use a package's menu to stack it on a show with room.")
                        .font(.small)
                        .foregroundStyle(Brand.secondary)
                }
                if payload.publishingConfigured == false {
                    Label("YouTube publishing isn't set up yet. Scheduling still works.", systemImage: "info.circle")
                        .font(.small)
                        .foregroundStyle(Brand.secondary)
                }
                if model.live.allSatisfy(\.packages.isEmpty) {
                    Text(model.past.isEmpty ? "Nothing in the queue yet." : "Nothing upcoming. Earlier shows are under Past shows.")
                        .font(.bodyText)
                        .foregroundStyle(Brand.secondary)
                }
                ForEach(model.live) { section in
                    showSection(section, payload: payload)
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.load(service) }
    }

    private func showSection(_ section: QueueLogic.Section, payload: QueuePayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            QueueShowHeader(label: label(section.date, payload: payload), count: section.packages.count,
                            openShow: payload.canEdit && section.date != QueueLogic.unassigned
                                ? { router.push(.publishing(.show(date: section.date))) } : nil)
            if section.packages.isEmpty {
                Text(payload.canEdit ? "Room for \(QueueLogic.maxPerShow) packages" : "No package yet")
                    .font(.small)
                    .foregroundStyle(Brand.muted)
                    .card(padding: 14)
            }
            ForEach(section.packages) { package in
                NavigationLink(value: Route.publishing(.package(rowId: package.id))) {
                    QueuePackageRow(package: package, busy: model.busyRowId == package.id,
                                    actions: payload.canEdit ? actions : nil)
                        .card(padding: 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var actions: QueueRowActions {
        QueueRowActions(move: { moving = $0 }, download: download, remove: { removing = $0 })
    }

    private func download(_ package: QueuePackage) {
        router.openPortal("api/package-cycle/queue/\(package.id)/download", title: "Final cut")
    }

    private func label(_ date: String, payload: QueuePayload) -> String {
        payload.upcomingShows.first { $0.date == date }?.label ?? QueueLogic.showLabel(date)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.payload != nil {
                Button("Past shows", systemImage: "clock.arrow.circlepath") { showPast = true }
            }
            if model.canEdit {
                Menu {
                    Button("Add package", systemImage: "plus") { showAdd = true }
                    Button("Website managers", systemImage: "person.2") { router.push(.publishing(.managers)) }
                    Button("Upload a whole show on the web", systemImage: "film.stack") {
                        router.openPortal("show-roles", title: "The Show")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Add and manage")
            }
        }
    }
}

extension View {
    /// The queue's error alert and success haptic, shared by every Publishing screen.
    func publishingAlerts(_ model: PublishingModel) -> some View {
        self
            .alert("Couldn't do that", isPresented: Binding(
                get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
            .sensoryFeedback(.success, trigger: model.successCount)
            .onChange(of: model.successCount) {
                if let notice = model.notice { AccessibilityNotification.Announcement(notice).post() }
            }
    }
}
