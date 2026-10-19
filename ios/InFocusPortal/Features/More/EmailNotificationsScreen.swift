import SwiftUI

/// Settings → Email notifications (the web's Settings → Notifications → Email card):
/// email on or off, where it goes, which kinds, and a test email. Every switch saves
/// at once and rolls back if the Portal refuses. The iPhone gets a notification for
/// every email, so this also decides what the phone shows.
struct EmailNotificationsScreen: View {
    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @State private var state: Loadable<NotificationPreferences> = .idle
    @State private var emailInput = ""
    @State private var emailError: String?
    @State private var saving = false
    @State private var sendingTest = false
    @State private var status: String?
    @State private var actionError: String?

    private var service: SettingsService { SettingsService(client: client) }

    var body: some View {
        LoadableView(state, retry: { Task { await load() } }) { preferences in
            form(preferences)
        }
        .brandBackground()
        .navigationTitle("Email notifications")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't save", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .task { await load() }
    }

    private func form(_ preferences: NotificationPreferences) -> some View {
        Form {
            Section {
                Toggle("Email me", isOn: Binding(get: { preferences.emailEnabled }, set: { on in
                    var next = preferences
                    next.emailEnabled = on
                    Task { await save(next) }
                }))
            } footer: {
                Text(preferences.emailEnabled ? "Emails go to \(preferences.notificationEmail ?? session.user?.email ?? "your account email")."
                     : "Email is off. You won't get Portal emails or the iPhone notifications that come with them.")
            }
            Section {
                ForEach(NotificationPreferences.Category.allCases) { category in
                    Toggle(category.label, isOn: Binding(get: { preferences.email(category) }, set: { on in
                        Task { await save(preferences.settingEmail(category, on)) }
                    }))
                }
            } header: {
                Text("Send me")
            } footer: {
                if !preferences.emailEnabled { Text("These apply when email is on.") }
            }
            Section {
                TextField("Notification email", text: $emailInput, prompt: Text(session.user?.email ?? "name@example.edu"))
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: emailInput) { _, _ in emailError = nil }
                if let emailError {
                    Text(emailError).font(.small).foregroundStyle(Brand.danger)
                }
                Button("Save address") { Task { await saveAddress(preferences) } }
                    .disabled(emailInput.trimmingCharacters(in: .whitespaces) == (preferences.notificationEmail ?? ""))
            } header: {
                Text("Send to")
            } footer: {
                Text("Leave empty to use your account email.")
            }
            Section {
                Button(sendingTest ? "Sending…" : "Send a test email") { Task { await sendTest() } }
                    .disabled(!preferences.emailEnabled || sendingTest)
                if let status {
                    Text(status).font(.small).foregroundStyle(Brand.green)
                }
            }
        }
        .toolsList()
        .disabled(saving)
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let preferences = try await service.notifications()
            state = .loaded(preferences)
            emailInput = preferences.notificationEmail ?? ""
        } catch {
            if state.value == nil { state = .failed(Loadable<NotificationPreferences>.message(for: error)) }
        }
    }

    /// Optimistic: shows the change, puts it back if the save fails.
    private func save(_ next: NotificationPreferences) async {
        guard let previous = state.value else { return }
        state = .loaded(next)
        saving = true
        defer { saving = false }
        do {
            let saved = try await service.saveNotifications(next)
            state = .loaded(saved)
            emailInput = saved.notificationEmail ?? ""
            status = "Saved."
        } catch {
            state = .loaded(previous)
            actionError = Loadable<Int>.message(for: error)
        }
    }

    private func saveAddress(_ preferences: NotificationPreferences) async {
        let address = emailInput.trimmingCharacters(in: .whitespaces)
        if !address.isEmpty && !AdminFormat.isEmail(address) {
            emailError = "Enter a valid notification email address."
            return
        }
        var next = preferences
        next.notificationEmail = address.isEmpty ? nil : address
        await save(next)
    }

    private func sendTest() async {
        sendingTest = true
        defer { sendingTest = false }
        do {
            try await service.sendTestEmail()
            status = "Test email sent."
        } catch {
            actionError = Loadable<Int>.message(for: error)
        }
    }
}
