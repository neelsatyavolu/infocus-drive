import SwiftUI

/// Settings → Appearance in November: the Thanksgiving theme and the giant turkey, on this iPhone.
struct SeasonalAppearanceRows: View {
    @State private var season = HarvestSeasonStore.shared

    var body: some View {
        if season.isSeason {
            Toggle("Thanksgiving theme", isOn: Binding(get: { !season.themeOff }, set: { season.themeOff = !$0 }))
                .tint(Brand.fill)
            Toggle("Giant turkey", isOn: Binding(get: { !season.turkeyOff }, set: { season.turkeyOff = !$0 }))
                .tint(Brand.fill)
                .disabled(season.themeOff)
        }
    }
}

/// More → Class → Leaderboard, while the season is on. The section is already hidden for the
/// App Review sample account; this checks again so it never reaches `api/thanksgiving`.
struct SeasonalLeaderboardRow: View {
    @Environment(SessionStore.self) private var session
    @State private var season = HarvestSeasonStore.shared

    var body: some View {
        if season.isOn, session.user?.sampleOnly == false {
            NavigationLink(value: Route.seasonal(.leaderboard)) {
                Label("Leaderboard", systemImage: "trophy")
            }
        }
    }
}
