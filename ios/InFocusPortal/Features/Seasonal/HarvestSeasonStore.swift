import Foundation
import Observation
import UIKit

/// This device's Thanksgiving state: whether it's the season today, the person's choices
/// (theme off, giant turkey off; Settings → Appearance), whether this year's welcome was seen,
/// and the leaves and pies caught here. Kept in UserDefaults. Setting `isOn` also flips
/// `HarvestPalette`, which the Brand colors read.
///
/// DEBUG: `-InFocusHarvest on` makes every day November (screenshots, tests); `-InFocusHarvest off`
/// makes none of them.
@MainActor @Observable
final class HarvestSeasonStore {
    static let shared = HarvestSeasonStore()

    private let defaults: UserDefaults
    private let clock: () -> Date
    private let calendar: Calendar
    private let forced: Bool?

    /// Today is in November (or forced).
    private(set) var isSeason = false
    /// The harvest theme is showing: in season and not turned off here.
    private(set) var isOn = false

    var themeOff: Bool {
        didSet {
            defaults.set(themeOff, forKey: Keys.themeOff)
            refresh()
        }
    }

    var turkeyOff: Bool { didSet { defaults.set(turkeyOff, forKey: Keys.turkeyOff) } }

    private(set) var leaves: Int
    private(set) var pies: Int

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current,
         clock: @escaping () -> Date = Date.init, forced: Bool? = HarvestSeasonStore.launchOverride) {
        self.defaults = defaults
        self.calendar = calendar
        self.clock = clock
        self.forced = forced
        themeOff = defaults.bool(forKey: Keys.themeOff)
        turkeyOff = defaults.bool(forKey: Keys.turkeyOff)
        leaves = defaults.integer(forKey: Keys.leaves)
        pies = defaults.integer(forKey: Keys.pies)
        refresh()
    }

    /// Re-reads the date. Call when the app comes back, at local midnight and when the clock changes.
    func refresh() {
        let now = clock()
        isSeason = forced ?? HarvestSeason.isSeason(now, calendar: calendar)
        let on = isSeason && !themeOff
        if on != isOn { isOn = on }
        HarvestPalette.set(on)
    }

    // MARK: Welcome

    var needsWelcome: Bool {
        isOn && HarvestSeason.needsWelcome(stored: defaults.string(forKey: Keys.welcomed), now: clock(), calendar: calendar)
    }

    func markWelcomed() {
        defaults.set(String(calendar.component(.year, from: clock())), forKey: Keys.welcomed)
    }

    // MARK: Counts on this device

    func countLeaf() -> Int {
        leaves += 1
        defaults.set(leaves, forKey: Keys.leaves)
        return leaves
    }

    func countPie() -> Int {
        pies += 1
        defaults.set(pies, forKey: Keys.pies)
        return pies
    }

    // MARK: Launch override

    nonisolated static var launchOverride: Bool? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "InFocusHarvest") {
        case "on"?: return true
        case "off"?: return false
        default: return nil
        }
        #else
        return nil
        #endif
    }

    enum Keys {
        static let themeOff = "harvest.themeOff"
        static let turkeyOff = "harvest.turkeyOff"
        static let welcomed = "harvest.welcomedYear"
        static let leaves = "harvest.leaves"
        static let pies = "harvest.pies"
    }
}

/// UIKit pieces that resolved a Brand color before the palette changed pick up the new one.
@MainActor
enum HarvestRedraw {
    static func uikit() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windows = (scene as? UIWindowScene)?.windows else { continue }
            for window in windows {
                // Re-sends tintColorDidChange down the tree, so dynamic tints resolve again.
                window.tintAdjustmentMode = .dimmed
                window.tintAdjustmentMode = .automatic
                window.setNeedsLayout()
            }
        }
    }
}
