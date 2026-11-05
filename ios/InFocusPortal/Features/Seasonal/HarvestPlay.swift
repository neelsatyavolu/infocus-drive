import Foundation
import Observation

/// What outlives the Home layer between visits to Home: the leaderboard tally and the giant
/// turkey's schedule (components/thanksgiving/giant-turkey.tsx: first visit 10–20 minutes in,
/// then every 30–60 minutes, only while someone's looking at Home).
@MainActor @Observable
final class HarvestPlay {
    static let giantFirstMin: TimeInterval = 10 * 60
    static let giantFirstSpread: TimeInterval = 10 * 60
    static let giantEveryMin: TimeInterval = 30 * 60
    static let giantEverySpread: TimeInterval = 30 * 60
    /// How long the giant turkey stays.
    static let giantLasts: TimeInterval = 10.6

    let tally: HarvestTally
    /// When the giant turkey on screen now walked in.
    private(set) var giantAt: Date?
    private var nextGiant: Date

    /// `firstGiantIn` overrides the first visit (DEBUG `-InFocusHarvestGiant YES` brings it in seconds).
    init(tally: HarvestTally, now: Date = Date(), firstGiantIn: TimeInterval? = nil) {
        self.tally = tally
        nextGiant = now.addingTimeInterval(firstGiantIn ?? (Self.giantFirstMin + .random(in: 0...Self.giantFirstSpread)))
    }

    /// Brings the giant turkey in when it's due (checked every couple of seconds on Home).
    /// It counts for the leaderboard the moment it walks in, like the web's.
    func checkGiant(allowed: Bool, now: Date = Date()) {
        if let giantAt, now.timeIntervalSince(giantAt) > Self.giantLasts { self.giantAt = nil }
        guard allowed, giantAt == nil, now >= nextGiant else { return }
        giantAt = now
        tally.giantTurkey()
        nextGiant = now.addingTimeInterval(Self.giantEveryMin + .random(in: 0...Self.giantEverySpread))
    }

    func dismissGiant() {
        giantAt = nil
    }
}
