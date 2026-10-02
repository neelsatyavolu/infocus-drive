import SwiftUI
import UIKit
import UserNotifications

@main
struct InFocusPortalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.launch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.becameActive() }
                }
        }
    }
}

/// Push plumbing that only UIKit's app delegate receives.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Set before launch finishes so a tap that cold-launched the app is delivered.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistrar.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushRegistrar.shared.didFail(error) }
    }
}
