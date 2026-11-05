import SwiftUI

/// The first time this iPhone opens the app each November: what the harvest theme does, and where
/// to turn it off (components/thanksgiving/thanksgiving-welcome.tsx, for a phone).
struct ThanksgivingWelcome: View {
    let openLeaderboard: () -> Void
    let close: () -> Void

    static let whatHappens: [(String, String)] = [
        ("Visitors drop by Home.", "Leaves fall, pies turn up at the edges and a turkey struts along the bottom. Tap the leaves and pies to catch them; the Portal keeps count."),
        ("Pardon the turkey.", "Tap a strutting turkey five times and it walks free. Once in a while a wishbone drifts down, too."),
        ("Watch for the big one.", "Now and then, a wild turkey as tall as your screen walks in and sizes you up."),
        ("Climb the board.", "Every leaf, pie, wishbone, giant turkey sighting and pardoned turkey counts on the class leaderboard (More → Leaderboard)."),
        ("Work still works.", "Everything under the visitors stays tappable, and they only visit Home.")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    LeafArt(variant: 1).frame(width: 40, height: 40).rotationEffect(.degrees(-20))
                    TurkeyArt().frame(width: 64, height: 56)
                    PieArt().frame(width: 46, height: 30)
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("The Portal is stuffed").headline(.h1)
                    Text("Through November 30, InFocus Portal is dressed for the harvest.")
                        .font(.bodyText)
                        .foregroundStyle(Brand.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.whatHappens, id: \.0) { title, detail in
                        (Text(title).font(.lexend(15, .semibold)).foregroundColor(Brand.foreground)
                            + Text(" ") + Text(detail).font(.lexend(15)).foregroundColor(Brand.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Too much? Turn the colors or the giant turkey off in Settings → Appearance.")
                    .font(.small)
                    .foregroundStyle(Brand.muted)
                VStack(spacing: 10) {
                    Button("Pass the gravy", action: close).buttonStyle(.brandPrimary)
                    Button("See the leaderboard", action: openLeaderboard).buttonStyle(.brandSecondary)
                }
                .padding(.top, 4)
            }
            .padding(24)
        }
        .brandBackground()
    }
}
