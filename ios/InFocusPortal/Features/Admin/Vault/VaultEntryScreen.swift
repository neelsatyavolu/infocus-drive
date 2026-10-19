import SwiftUI

/// One login: copy the username, show or copy the password (asked first; logged),
/// the current 2FA code, notes for producers, recent activity, and Edit / Share.
/// Revealed values stay only in this screen's memory: they hide after 30 seconds,
/// when the app leaves the foreground, and when the screen closes.
struct VaultEntryScreen: View {
    let entryId: String

    @Environment(\.portalClient) private var client
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var state: Loadable<VaultEntry> = .idle
    @State private var notAvailable = false
    @State private var activity: [VaultActivity]?
    @State private var password: String?
    @State private var notes: String?
    @State private var totp: (code: String, expires: Date)?
    @State private var busy: String?
    @State private var confirming: VaultRevealKind?
    @State private var copied: String?
    @State private var editing = false
    @State private var sharing = false
    @State private var actionError: String?
    @State private var hideTask: Task<Void, Never>?

    private var service: VaultService { VaultService(client: client) }
    static let revealSeconds: UInt64 = 30

    var body: some View {
        Group {
            if notAvailable {
                NotAvailableView(message: "This login isn't shared with you.")
            } else {
                LoadableView(state, retry: { Task { await load() } }) { entry in
                    content(entry)
                }
            }
        }
        .brandBackground()
        .navigationTitle(state.value?.name ?? "Login")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let entry = state.value {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if entry.canShare { Button("Share", systemImage: "person.2") { sharing = true } }
                    if entry.canEdit { Button("Edit") { editing = true } }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let entry = state.value {
                VaultEditorSheet(entry: entry, service: service) { deleted in
                    if deleted { dismiss() } else { Task { await load() } }
                }
            }
        }
        .sheet(isPresented: $sharing) {
            if let entry = state.value {
                VaultShareSheet(entry: entry, service: service) { Task { await load() } }
            }
        }
        .confirmationDialog(confirming?.question ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let kind = confirming {
                Button(kind.action) { Task { await reveal(kind) } }
            }
        } message: {
            Text("Viewing is logged with your name. It hides again after 30 seconds.")
        }
        .actionErrorAlert($actionError)
        .onChange(of: scenePhase) { _, phase in if phase != .active { hideSecrets() } }
        .onDisappear { hideSecrets() }
        .task { await load() }
    }

    private func content(_ entry: VaultEntry) -> some View {
        List {
            Section {
                Nameplate(eyebrow: "Login", title: entry.name, subtitle: entry.host)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                if let website = entry.website {
                    Link(destination: website) {
                        LabeledContent("Website") { Text(entry.host ?? website.absoluteString).foregroundStyle(Brand.green) }
                    }
                }
                if let username = entry.username, !username.isEmpty {
                    SecretRow(label: "Username", value: username, mono: false, copyLabel: "Copy username",
                              copied: copied == "username") { copy(username, as: "username") }
                }
                if entry.hasPassword {
                    passwordRow(entry)
                }
                if entry.hasTotp {
                    totpRow(entry)
                }
                if entry.hasNotes && entry.canEdit {
                    notesRow
                }
                if let copied {
                    Text("\(copied.capitalized) copied. The clipboard clears in 90 seconds.")
                        .font(.small).foregroundStyle(Brand.green)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            Section {
                LabeledContent("Updated", value: AdminFormat.when(entry.updatedAt))
                if let by = entry.updatedBy { LabeledContent("By", value: by) }
                if entry.sharedWith > 0 {
                    LabeledContent("Shared with", value: entry.sharedWith == 1 ? "1 person" : "\(entry.sharedWith) people")
                }
            }
            if let activity, entry.canEdit {
                Section("Recent activity") {
                    if activity.isEmpty { Text("Nothing yet.").foregroundStyle(Brand.secondary) }
                    ForEach(activity) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label).foregroundStyle(Brand.foreground)
                                Text(row.actor).font(.small).foregroundStyle(Brand.muted)
                            }
                            Spacer()
                            Text(AdminFormat.when(row.createdAt)).font(.mono(12)).foregroundStyle(Brand.muted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .toolsList()
        .refreshable { await load() }
    }

    private func passwordRow(_ entry: VaultEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Password").font(.small).foregroundStyle(Brand.muted)
            Text(password ?? "••••••••••")
                .font(.mono(16))
                .foregroundStyle(Brand.foreground)
                .textSelection(.disabled)
                .privacySensitive()
                .accessibilityLabel(password == nil ? "Hidden" : "Password shown")
            HStack(spacing: 8) {
                Button(password == nil ? "Show" : "Hide") {
                    if password == nil { confirming = .password } else { password = nil }
                }
                .buttonStyle(.brandSecondary)
                Button(copied == "password" ? "Copied" : "Copy") { Task { await copyPassword(entry) } }
                    .buttonStyle(.brandSecondary)
            }
            .disabled(busy != nil)
        }
        .padding(.vertical, 6)
    }

    private func totpRow(_ entry: VaultEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2FA code").font(.small).foregroundStyle(Brand.muted)
            if let totp {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(totp.expires.timeIntervalSince(context.date).rounded(.up)))
                    HStack {
                        Text(VaultTotp.grouped(totp.code)).font(.mono(22, .medium)).foregroundStyle(Brand.foreground)
                            .privacySensitive()
                        Spacer()
                        Text("\(left)s").font(.mono(13)).monospacedDigit().foregroundStyle(Brand.muted)
                            .accessibilityLabel("\(left) seconds left")
                    }
                    .onChange(of: left == 0) { _, expired in if expired { self.totp = nil } }
                }
                Button(copied == "2FA code" ? "Copied" : "Copy code") { copy(totp.code, as: "2FA code") }
                    .buttonStyle(.brandSecondary)
            } else {
                Button(busy == "totp" ? "Getting code…" : "Show code") { confirming = .totp }
                    .buttonStyle(.brandSecondary)
                    .disabled(busy != nil)
            }
        }
        .padding(.vertical, 6)
    }

    private var notesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.small).foregroundStyle(Brand.muted)
            if let notes {
                Text(notes).foregroundStyle(Brand.foreground).privacySensitive()
            }
            Button(notes == nil ? "Show notes" : "Hide notes") {
                if notes == nil { confirming = .notes } else { notes = nil }
            }
            .buttonStyle(.brandSecondary)
            .disabled(busy != nil)
        }
        .padding(.vertical, 6)
    }

    // MARK: Actions

    private func load() async {
        await ToolLoad.run($state, notAvailable: $notAvailable) {
            guard let entry = try await service.entries().first(where: { $0.id == entryId }) else { throw PortalError.notFound }
            return entry
        }
        if let entry = state.value, entry.canEdit {
            activity = try? await service.activity(of: entryId)
        }
        hideSecrets() // an edit may have changed what was shown
    }

    private func reveal(_ kind: VaultRevealKind) async {
        busy = kind.rawValue
        defer { busy = nil }
        do {
            switch kind {
            case .password: password = try await service.reveal("password", of: entryId)
            case .notes: notes = try await service.reveal("notes", of: entryId)
            case .totp:
                let code = try await service.totp(of: entryId)
                totp = (code.code, Date().addingTimeInterval(TimeInterval(code.secondsRemaining)))
            }
            scheduleHide()
            activity = try? await service.activity(of: entryId)
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }

    /// A hidden password is revealed (and logged) only to copy it; it stays hidden on screen.
    private func copyPassword(_ entry: VaultEntry) async {
        if let password { return copy(password, as: "password") }
        busy = "copy"
        defer { busy = nil }
        do {
            copy(try await service.reveal("password", of: entry.id), as: "password")
            if entry.canEdit { activity = try? await service.activity(of: entryId) }
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }

    private func copy(_ value: String, as label: String) {
        VaultService.copy(value)
        copied = label
        UIAccessibility.post(notification: .announcement, argument: "\(label.capitalized) copied")
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: Self.revealSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            password = nil
            notes = nil
        }
    }

    private func hideSecrets() {
        hideTask?.cancel()
        password = nil
        notes = nil
        totp = nil
    }
}

/// What a confirmation is about to reveal.
enum VaultRevealKind: String, Identifiable {
    case password, notes, totp

    var id: String { rawValue }

    var question: String {
        switch self {
        case .password: "Show the password?"
        case .notes: "Show the notes?"
        case .totp: "Show the 2FA code?"
        }
    }

    var action: String {
        switch self {
        case .password: "Show password"
        case .notes: "Show notes"
        case .totp: "Show code"
        }
    }
}

/// A value with a copy button (the username).
private struct SecretRow: View {
    let label: String
    let value: String
    let mono: Bool
    let copyLabel: String
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.small).foregroundStyle(Brand.muted)
                Text(value).font(mono ? .mono(15) : .bodyText).foregroundStyle(Brand.foreground)
            }
            Spacer()
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.green)
            .accessibilityLabel(copyLabel)
        }
    }
}
