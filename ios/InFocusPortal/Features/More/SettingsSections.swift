import SwiftUI

/// Settings → Profile: the nickname the Portal shows everyone, beside the Google
/// account name and email (which sign-in keeps and the nickname never overwrites).
struct ProfileSection: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @State private var profile: ProfileInfo?
    @State private var nickname = ""
    @State private var saving = false
    @State private var message: (text: String, error: Bool)?

    private var service: SettingsService { SettingsService(client: client) }
    private var trimmed: String { nickname.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Section {
            if let user = session.user {
                LabeledContent("Name", value: profile?.name ?? user.name)
                LabeledContent("Email", value: profile?.email ?? user.email)
                LabeledContent("Role", value: user.roleLabel)
            }
            HStack {
                TextField("Nickname", text: $nickname, prompt: Text("What should we call you?"))
                    .onChange(of: nickname) { _, value in
                        if value.count > ProfileInfo.nicknameMax { nickname = String(value.prefix(ProfileInfo.nicknameMax)) }
                    }
                    .disabled(profile == nil || saving)
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(profile == nil || trimmed == (profile?.nickname ?? ""))
                }
            }
            if let message {
                Text(message.text).font(.small).foregroundStyle(message.error ? Brand.danger : Brand.green)
            }
        } header: {
            Text("Profile")
        } footer: {
            Text("Your nickname shows on rosters, calendars and comments. Signing in with Google won't overwrite it.")
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let loaded = try await service.profile()
            profile = loaded
            nickname = loaded.nickname ?? ""
        } catch {
            message = (Loadable<Int>.message(for: error), true)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let saved = try await service.saveNickname(trimmed.isEmpty ? nil : trimmed)
            profile = saved
            nickname = saved.nickname ?? ""
            message = ("Saved.", false)
            await session.load(using: client) // the app shows the new name
        } catch {
            message = (Loadable<Int>.message(for: error), true)
        }
    }
}

/// Settings → PINs: the Class Board and livestream dashboard kiosk PINs, for the people
/// the Portal shows them to (`pins` holds only the ones that loaded). Hidden for everyone else.
struct AccessPinsSection: View {
    @Binding var pins: [AccessPinKind: AccessPin]
    @Environment(\.portalClient) private var client
    @State private var renewing: AccessPinKind?
    @State private var busy: AccessPinKind?
    @State private var error: String?

    private var service: SettingsService { SettingsService(client: client) }

    var body: some View {
        Group {
            if !pins.isEmpty {
                Section {
                    ForEach(AccessPinKind.allCases.filter { pins[$0] != nil }) { kind in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title).foregroundStyle(Brand.foreground)
                                Text(pins[kind]?.pin ?? "Not set")
                                    .font(pins[kind]?.pin == nil ? .small : .mono(20, .medium))
                                    .foregroundStyle(pins[kind]?.pin == nil ? Brand.muted : Brand.foreground)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if busy == kind { ProgressView() } else {
                                Button(pins[kind]?.pin == nil ? "Create" : "New PIN") {
                                    if pins[kind]?.pin == nil { Task { await renew(kind) } } else { renewing = kind }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    if let error {
                        Text(error).font(.small).foregroundStyle(Brand.danger)
                    }
                } header: {
                    Text("PINs")
                } footer: {
                    Text("Kiosk devices sign in to the Class Board and livestream dashboard with these.")
                }
            }
        }
        .confirmationDialog("Replace the \(renewing?.title ?? "PIN")?",
                            isPresented: Binding(get: { renewing != nil }, set: { if !$0 { renewing = nil } }),
                            titleVisibility: .visible) {
            Button("Replace PIN", role: .destructive) {
                if let kind = renewing { Task { await renew(kind) } }
            }
        } message: {
            Text(renewing?.replaceWarning ?? "")
        }
    }

    /// The PINs this person may see (none in the sample app).
    static func load(_ service: SettingsService) async -> [AccessPinKind: AccessPin] {
        var pins: [AccessPinKind: AccessPin] = [:]
        for kind in AccessPinKind.allCases {
            if let pin = await service.pin(kind) { pins[kind] = pin }
        }
        return pins
    }

    private func renew(_ kind: AccessPinKind) async {
        busy = kind
        defer { busy = nil }
        do {
            pins[kind] = try await service.renewPin(kind)
            error = nil
        } catch {
            self.error = Loadable<Int>.message(for: error)
        }
    }
}

/// Settings → Signature row, shown only to people the Portal lets draw one
/// (executive producers and the super admin; it goes on certificates).
struct SignatureSection: View {
    /// nil hides the section (the Portal refused, or it hasn't loaded).
    @Binding var signature: SignatureInfo?

    var body: some View {
        Group {
            if let signature {
                Section {
                    NavigationLink {
                        SignatureScreen(initial: signature.signature) { self.signature = SignatureInfo(signature: $0) }
                    } label: {
                        LabeledContent("Signature", value: signature.signature == nil ? "Not set" : "Saved")
                    }
                } header: {
                    Text("Signature")
                } footer: {
                    Text("Printed on certificates you sign.")
                }
            }
        }
    }
}
