import SwiftUI
import UIKit

extension View {
    /// The Thanksgiving season at the app's root (RootView): redraws everything in the harvest
    /// colors when the season starts, ends or is turned off; the yearly welcome; the visitors on
    /// Home; and the leaderboard tally, sent when the app goes to the background.
    func harvestSeason() -> some View { modifier(HarvestSeasonRoot()) }
}

private struct HarvestSeasonRoot: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.portalClient) private var client
    @Environment(\.scenePhase) private var scenePhase
    @State private var season = HarvestSeasonStore.shared
    @State private var play: HarvestPlay?
    @State private var welcoming = false
    /// The welcome stepped aside for the notifications offer; it comes back after.
    @State private var welcomeDeferred = false

    func body(content: Content) -> some View {
        content
            // Brand's colors read the season when they draw, so a new identity redraws them all.
            .id(season.isOn)
            .overlay {
                if showsVisitors, let play {
                    HarvestLayer(play: play, season: season)
                }
            }
            .sheet(isPresented: $welcoming, onDismiss: welcomeClosed) {
                ThanksgivingWelcome(openLeaderboard: openLeaderboard, close: { welcoming = false })
            }
            .task(id: welcomeReady) { await welcomeIfNeeded() }
            .task { await refreshAtMidnight() }
            .onAppear { makePlay() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                season.refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: season.refresh()
                case .background: flushInBackground()
                default: break
                }
            }
            .onChange(of: season.isOn) { _, _ in HarvestRedraw.uikit() }
            .onChange(of: model.offeringNotifications) { _, offering in
                guard offering, welcoming else { return }
                welcomeDeferred = true
                welcoming = false
            }
    }

    private var isClassMember: Bool {
        model.phase == .signedIn && session.user != nil && session.user?.sampleOnly == false
    }

    /// Home's root, in front, with nothing over it.
    private var showsVisitors: Bool {
        season.isOn && isClassMember && scenePhase == .active && !welcoming && !model.offeringNotifications
            && router.selectedTab == .home && (router.paths[.home] ?? []).isEmpty && router.activeCall == nil
    }

    private var welcomeReady: Bool {
        season.isOn && isClassMember && !model.offeringNotifications
    }

    private func makePlay() {
        guard play == nil else { return }
        let client = client
        let tally = HarvestTally(send: { batch in try await HarvestAPI.current(client).send(batch) })
        #if DEBUG
        let firstGiant: TimeInterval? = UserDefaults.standard.bool(forKey: "InFocusHarvestGiant") ? 6 : nil
        #else
        let firstGiant: TimeInterval? = nil
        #endif
        play = HarvestPlay(tally: tally, firstGiantIn: firstGiant)
    }

    // MARK: Welcome

    private func welcomeIfNeeded() async {
        guard welcomeReady, season.needsWelcome else { return }
        // Give a fresh sign-in a moment to ask about notifications first.
        await harvestSleep(2.5)
        guard !Task.isCancelled, welcomeReady, season.needsWelcome else { return }
        welcomeDeferred = false
        welcoming = true
    }

    private func welcomeClosed() {
        if welcomeDeferred { return }
        season.markWelcomed()
    }

    private func openLeaderboard() {
        welcoming = false
        router.select(.more)
        router.push(.seasonal(.leaderboard), on: .more)
    }

    // MARK: Clock

    private func refreshAtMidnight() async {
        while !Task.isCancelled {
            let midnight = HarvestSeason.nextMidnight(after: Date())
            await harvestSleep(midnight.timeIntervalSinceNow + 1)
            season.refresh()
        }
    }

    // MARK: Tally

    private func flushInBackground() {
        guard let play else { return }
        let application = UIApplication.shared
        var taskId = UIBackgroundTaskIdentifier.invalid
        taskId = application.beginBackgroundTask(withName: "Harvest tally") {
            application.endBackgroundTask(taskId)
        }
        Task {
            await play.tally.flush()
            application.endBackgroundTask(taskId)
        }
    }
}
