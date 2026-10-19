import SwiftUI

/// Settings, the native `/settings`: profile (nickname), notifications on this iPhone and
/// by email, kiosk PINs and signature (for those who have them), appearance, about, sign out.
struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(SessionStore.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(\.portalClient) private var client
    @State private var notifications: PushRegistrar.Status?
    @State private var testResult: String?
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var pins: [AccessPinKind: AccessPin] = [:]
    @State private var signature: SignatureInfo?

    /// Deletion requests go to InFocus (the adviser manages accounts).
    static let deletionRequestURL = URL(string: "https://infocusnews.tv/contact-us/")!

    var body: some View {
        @Bindable var preferences = preferences
        List {
            if session.user != nil {
                ProfileSection()
            }
            Section {
                NotificationRows(status: notifications, testResult: testResult,
                                 turnOn: turnOnNotifications, sendTest: sendTest)
                NavigationLink("Email notifications") { EmailNotificationsScreen() }
            } header: {
                Text("Notifications")
            } footer: {
                Text("You get a notification for every email the Portal sends you. Email notifications sets which emails you get.")
            }
            if session.user?.sampleOnly == false {
                AccessPinsSection(pins: $pins)
                SignatureSection(signature: $signature)
            }
            Section {
                NavigationLink("Blocked people") { BlockedPeopleScreen() }
            } header: {
                Text("Messages")
            } footer: {
                Text("Report a message from its menu (press and hold). Reports go to the InFocus adviser and executive producers.")
            }
            Section("Appearance") {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section("About") {
                LabeledContent("Version", value: "\(AppConfig.appVersion) (\(Self.build))")
                if let portal = AppConfig.shared.portalURL {
                    Link("Privacy policy", destination: portal.appendingPathComponent("privacy"))
                    Link("Support", destination: portal.appendingPathComponent("support"))
                }
            }
            Section {
                Button("Sign out", role: .destructive) { confirmingSignOut = true }
                    .frame(maxWidth: .infinity)
            }
            Section {
                Button("Delete account", role: .destructive) { confirmingDelete = true }
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("InFocus Portal accounts are created and managed by the InFocus class. The adviser deletes an account and its data when you ask.")
            }
        }
        .font(.bodyText)
        .scrollContentBackground(.hidden)
        .brandBackground()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            notifications = await PushRegistrar.shared.status()
            await loadExtras()
        }
        .refreshable {
            await session.load(using: client)
            notifications = await PushRegistrar.shared.status()
            await loadExtras()
        }
        .confirmationDialog("Sign out of InFocus Portal?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { model.signOut() }
        } message: {
            Text("This iPhone stops getting Portal notifications until you sign in again.")
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Request deletion", role: .destructive) { Presenter.showSafari(Self.deletionRequestURL) }
        } message: {
            Text("The InFocus adviser deletes your Portal account and its data (uploads, comments, grades and messages). Send the request from the InFocus contact page.")
        }
    }

    /// PINs and signature: only for the people the Portal shows them to.
    private func loadExtras() async {
        guard session.user?.sampleOnly == false else { return }
        let service = SettingsService(client: client)
        pins = await AccessPinsSection.load(service)
        signature = await service.signature()
    }

    private static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private func turnOnNotifications() {
        Task { notifications = await PushRegistrar.shared.requestPermission() }
    }

    private func sendTest() {
        testResult = nil
        Task {
            do {
                try await client.post("api/push/native-device/test", body: PortalJSON.EmptyBody())
                testResult = "Test notification sent."
            } catch {
                testResult = Loadable<String>.message(for: error)
            }
        }
    }
}

/// Status, Turn on / Open iPhone Settings, and Test, like the Portal's Settings card.
private struct NotificationRows: View {
    let status: PushRegistrar.Status?
    let testResult: String?
    let turnOn: () -> Void
    let sendTest: () -> Void

    var body: some View {
        Text(statusText).foregroundStyle(Brand.secondary)
        if status?.permission == "notDetermined" {
            Button("Turn on notifications", action: turnOn)
        } else {
            Button("Open iPhone notification settings") { PushRegistrar.shared.openSystemSettings() }
        }
        if allowed, status?.registered == true {
            Button("Send a test notification", action: sendTest)
        }
        if let testResult {
            Text(testResult).font(.small).foregroundStyle(Brand.muted)
        }
    }

    private var allowed: Bool { status?.permission == "authorized" || status?.permission == "provisional" }

    private var statusText: String {
        switch (status?.permission, status?.registered) {
        case (nil, _): "Checking this iPhone…"
        case ("denied", _): "Off in iPhone Settings. Turn on notifications for InFocus Portal there."
        case ("notDetermined", _): "Not set up yet."
        case (_, false?): "Allowed, but this iPhone isn't registered with the Portal yet. Reopen the app if this doesn't change."
        default: "On for this iPhone."
        }
    }
}
