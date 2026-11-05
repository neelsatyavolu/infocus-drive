import Foundation
import Observation
import SwiftUI

/// One thing on screen in the harvest layer.
struct HarvestSprite: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Falls from the top, swaying.
        case leaf(variant: Int)
        /// Sits at the left or right edge for a while.
        case pie(leftSide: Bool, y: CGFloat)
        /// Walks along the bottom; `taps` toward a pardon.
        case strut(rightToLeft: Bool, taps: Int, pardoned: Bool, lastTap: Date?)
        /// Drifts down slowly (rare).
        case wishbone
        /// Blows across the screen; can't be caught.
        case gust(variant: Int, y: CGFloat, spin: Double)
        /// "+1" where something was caught.
        case cheer(text: String, x: CGFloat, y: CGFloat)
    }

    let id: Int
    var kind: Kind
    let bornAt: Date
    /// Seconds on screen.
    let duration: TimeInterval
    /// Where along the top it starts (0–1 of the width), for falling things.
    var x: CGFloat = 0
    /// How far it sways (points), for falling things.
    var sway: CGFloat = 0

    var isCatchable: Bool {
        switch kind {
        case .leaf, .pie, .strut, .wishbone: true
        case .gust, .cheer: false
        }
    }

    /// 0 when it appeared, 1 when it leaves.
    func progress(at now: Date) -> Double {
        min(max(now.timeIntervalSince(bornAt) / duration, 0), 1)
    }
}

/// The visitors' schedule (components/thanksgiving/thanksgiving-goodies.tsx): the first one after
/// 3 s, then one every 9–18 s: leaves (3–6 at a time), a pie (at most 3 on screen), a strutting
/// turkey, a gust of leaves or, rarely, a wishbone. With Reduce Motion only pies come, and they
/// sit still. The giant turkey keeps its own, much slower, schedule (`HarvestPlay`).
@MainActor @Observable
final class HarvestGame {
    enum Visitor: CaseIterable { case leaves, pie, strut, gust, wishbone }

    static let weights: [(Visitor, Double)] = [(.leaves, 40), (.pie, 25), (.strut, 20), (.gust, 15), (.wishbone, 3)]
    static let firstVisit: TimeInterval = 3
    static let visitMin: TimeInterval = 9
    static let visitSpread: TimeInterval = 9
    static let pieStays: TimeInterval = 15
    static let maxPies = 3

    private(set) var sprites: [HarvestSprite] = []
    /// A short line at the top (a wish, a pardon, a leaf milestone).
    private(set) var note: String?

    var reduceMotion = false
    private var nextId = 0
    private var schedule: Task<Void, Never>?
    /// Pending removals and staggered spawns, by key, so stopping cancels them all.
    private var timers: [Int: Task<Void, Never>] = [:]
    private var nextTimer = 0

    func start() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            await harvestSleep(Self.firstVisit)
            while !Task.isCancelled {
                self?.visit()
                await harvestSleep(Self.visitMin + .random(in: 0...Self.visitSpread))
            }
        }
    }

    func stop() {
        schedule?.cancel()
        schedule = nil
        timers.values.forEach { $0.cancel() }
        timers = [:]
        sprites = []
        note = nil
    }

    static func pick(_ roll: Double) -> Visitor {
        var left = roll * weights.reduce(0) { $0 + $1.1 }
        for (visitor, weight) in weights {
            left -= weight
            if left < 0 { return visitor }
        }
        return .leaves
    }

    func visit() {
        var visitor = reduceMotion ? .pie : Self.pick(.random(in: 0..<1))
        if visitor == .pie, sprites.filter({ if case .pie = $0.kind { true } else { false } }).count >= Self.maxPies {
            if reduceMotion { return }
            visitor = .leaves
        }
        switch visitor {
        case .leaves:
            let count = Int.random(in: 3...6)
            for i in 0..<count {
                later(Double(i) * .random(in: 0.3...0.8)) { [weak self] in
                    self?.spawn(.leaf(variant: .random(in: 0..<HarvestArt.leafColors.count)),
                                duration: .random(in: 9...14), x: .random(in: 0.06...0.94), sway: .random(in: 16...40))
                }
            }
        case .pie:
            spawn(.pie(leftSide: Bool.random(), y: .random(in: 0.3...0.7)), duration: Self.pieStays)
        case .strut:
            spawn(.strut(rightToLeft: Bool.random(), taps: 0, pardoned: false, lastTap: nil), duration: .random(in: 12...16))
        case .gust:
            for i in 0..<10 {
                later(Double(i) * 0.06) { [weak self] in
                    self?.spawn(.gust(variant: .random(in: 0..<HarvestArt.leafColors.count), y: .random(in: 0.08...0.85),
                                      spin: .random(in: 360...1080)), duration: .random(in: 2.6...4))
                }
            }
        case .wishbone:
            spawn(.wishbone, duration: .random(in: 14...18), x: .random(in: 0.12...0.85), sway: .random(in: 14...28))
        }
    }

    @discardableResult
    func spawn(_ kind: HarvestSprite.Kind, duration: TimeInterval, x: CGFloat = 0, sway: CGFloat = 0, now: Date = Date()) -> Int {
        nextId += 1
        let id = nextId
        sprites.append(HarvestSprite(id: id, kind: kind, bornAt: now, duration: duration, x: x, sway: sway))
        later(duration + 0.1) { [weak self] in self?.remove(id) }
        return id
    }

    func remove(_ id: Int) {
        sprites.removeAll { $0.id == id }
    }

    /// One tap on a strutting turkey. Returns true on the tap that pardons it.
    func tapTurkey(_ id: Int, now: Date = Date()) -> (taps: Int, pardoned: Bool)? {
        guard let index = sprites.firstIndex(where: { $0.id == id }),
              case .strut(let rtl, let taps, let pardoned, _) = sprites[index].kind, !pardoned else { return nil }
        let next = taps + 1
        sprites[index].kind = .strut(rightToLeft: rtl, taps: next, pardoned: next >= HarvestSeason.pardonTaps, lastTap: now)
        return (next, next >= HarvestSeason.pardonTaps)
    }

    /// Takes back a pardon the Portal wouldn't count (the turkey was too new): one more tap does it.
    func unpardon(_ id: Int) {
        guard let index = sprites.firstIndex(where: { $0.id == id }),
              case .strut(let rtl, _, _, let lastTap) = sprites[index].kind else { return }
        sprites[index].kind = .strut(rightToLeft: rtl, taps: HarvestSeason.pardonTaps - 1, pardoned: false, lastTap: lastTap)
    }

    func cheer(_ text: String, at point: CGPoint) {
        spawn(.cheer(text: text, x: point.x, y: point.y), duration: 1.2)
    }

    func show(_ text: String) {
        note = text
        later(3) { [weak self] in
            if self?.note == text { self?.note = nil }
        }
    }

    private func later(_ seconds: TimeInterval, _ run: @escaping @MainActor () -> Void) {
        nextTimer += 1
        let key = nextTimer
        timers[key] = Task { [weak self] in
            await harvestSleep(seconds)
            guard !Task.isCancelled else { return }
            self?.timers[key] = nil
            run()
        }
    }
}

/// Sleeps, returning early (without throwing) when the task is cancelled.
func harvestSleep(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}
