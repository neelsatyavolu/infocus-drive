import SwiftUI

/// Admin → Backups (super admin): the latest nightly database backup, the stored
/// dumps (each downloads from a short-lived signed link) and Back up now.
struct BackupsScreen: View {
    @Environment(\.portalClient) private var client
    @State private var state: Loadable<BackupStatus> = .idle
    @State private var notAvailable = false
    @State private var busy: String?
    @State private var actionError: String?
    @State private var notice: String?

    private var service: AdminService { AdminService(client: client) }

    var body: some View {
        Group {
            if notAvailable {
                NotAvailableView(message: "Backups are for the super admin.")
            } else {
                LoadableView(state, retry: { Task { await load() } }) { status in
                    list(status)
                }
            }
        }
        .brandBackground()
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .actionErrorAlert($actionError)
        .task { await load() }
    }

    @ViewBuilder
    private func list(_ status: BackupStatus) -> some View {
        if !status.configured {
            NotAvailableView(title: "Backups aren't set up", message: "The Portal has no backup storage configured.")
        } else {
            List {
                Section {
                    if let latest = status.latest {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(AdminFormat.when(latest.at)).foregroundStyle(Brand.foreground)
                                if let bytes = latest.bytes {
                                    Text(AdminFormat.storage(bytes)).font(.mono(13)).foregroundStyle(Brand.muted)
                                }
                                if let error = latest.error, !latest.ok {
                                    Text(error).font(.small).foregroundStyle(Brand.danger)
                                }
                            }
                            Spacer()
                            StatusTag(text: latest.ok ? "OK" : "Failed", tone: latest.ok ? .success : .danger)
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        Text("No backup has run yet.").foregroundStyle(Brand.secondary)
                    }
                    Button { Task { await runNow() } } label: {
                        HStack {
                            Label("Back up now", systemImage: "arrow.clockwise")
                            if busy == "run" { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy != nil)
                    if let notice {
                        Text(notice).font(.small).foregroundStyle(Brand.green)
                    }
                } header: {
                    Text("Latest")
                }
                Section("Stored backups") {
                    if status.dumps.isEmpty {
                        Text("None stored.").foregroundStyle(Brand.secondary)
                    }
                    ForEach(status.dumps) { dump in
                        Button { Task { await download(dump) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dump.fileName).font(.mono(14)).foregroundStyle(Brand.foreground)
                                    Text("\(AdminFormat.when(dump.lastModified)) · \(AdminFormat.storage(dump.bytes))")
                                        .font(.small).foregroundStyle(Brand.muted)
                                }
                                Spacer()
                                if busy == dump.key { ProgressView() } else {
                                    Image(systemName: "arrow.down.circle").foregroundStyle(Brand.green)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityHint("Downloads in Safari")
                        .disabled(busy != nil)
                    }
                }
            }
            .toolsList()
            .refreshable { await load() }
        }
    }

    private func load() async {
        await ToolLoad.run($state, notAvailable: $notAvailable) { try await service.backups() }
    }

    private func runNow() async {
        busy = "run"
        defer { busy = nil }
        do {
            try await service.runBackup()
            notice = "Backup queued. It shows here when it finishes."
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }

    private func download(_ dump: BackupStatus.Dump) async {
        busy = dump.key
        defer { busy = nil }
        do {
            let url = try await service.backupDownloadURL(key: dump.key)
            Presenter.showSafari(url)
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }
}
