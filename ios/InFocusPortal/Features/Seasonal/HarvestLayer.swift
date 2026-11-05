import SwiftUI
import UIKit

/// The harvest visitors over Home: leaves, pies, a strutting turkey, gusts, a rare wishbone and,
/// now and then, the giant turkey. Only the visitors themselves take taps; everything between
/// them reaches Home underneath. Positions are worked out every frame, so a tap lands on a
/// visitor where it's drawn. With Reduce Motion only still pies come (no giant turkey).
struct HarvestLayer: View {
    let play: HarvestPlay
    let season: HarvestSeasonStore
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var game = HarvestGame()

    /// Keeps the turkey's lane above the tab bar.
    static let tabBarClearance: CGFloat = 60

    static let wishes = [
        "May your A-roll be in focus.",
        "May every interview subject sign the release form.",
        "May your audio never peak.",
        "May your Final Cut upload on the first try.",
        "May the teleprompter never outrun the anchor.",
        "May you nail your stand-up in one take.",
        "May your b-roll be plentiful and steady.",
        "May the SD card have room for one more shot.",
        "May no one say \"um\" in your best soundbite.",
        "May your pitch get approved the first time.",
        "May the batteries be charged when you need them.",
        "May your package make the show this week."
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            TimelineView(.animation(minimumInterval: 1 / 60, paused: game.sprites.isEmpty && play.giantAt == nil)) { timeline in
                let now = timeline.date
                ZStack(alignment: .topLeading) {
                    if let start = play.giantAt, !season.turkeyOff, !reduceMotion {
                        GiantTurkeyView(start: start, now: now, size: size)
                    }
                    ForEach(game.sprites) { sprite in
                        spriteView(sprite, now: now, size: size)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .overlay(alignment: .topTrailing) { counter.padding(.top, 8).padding(.trailing, Brand.gutter) }
            .overlay(alignment: .top) { noteView.padding(.top, 56).padding(.horizontal, Brand.gutter) }
        }
        .onAppear {
            game.reduceMotion = reduceMotion
            game.start()
        }
        .onDisappear { game.stop() }
        .onChange(of: reduceMotion) { _, still in game.reduceMotion = still }
        .task {
            while !Task.isCancelled {
                play.checkGiant(allowed: !season.turkeyOff && !reduceMotion)
                await harvestSleep(2)
            }
        }
    }

    // MARK: Sprites

    @ViewBuilder
    private func spriteView(_ sprite: HarvestSprite, now: Date, size: CGSize) -> some View {
        let t = sprite.progress(at: now)
        let age = now.timeIntervalSince(sprite.bornAt)
        switch sprite.kind {
        case .leaf(let variant):
            catchable(sprite, at: falling(sprite, t: t, size: size), label: "Falling leaf") {
                LeafArt(variant: variant).frame(width: 28, height: 28)
                    .rotationEffect(.degrees(sin(t * .pi * 3) * 40 + Double(variant) * 30))
            }
        case .wishbone:
            catchable(sprite, at: falling(sprite, t: t, size: size), label: "Wishbone") {
                WishboneArt().frame(width: 30, height: 38).rotationEffect(.degrees(sin(t * .pi * 2) * 20))
            }
        case .pie(let leftSide, let y):
            let fade = min(1, (sprite.duration - age) / 0.5)
            let grow = reduceMotion ? 1 : min(1, age / 0.3)
            catchable(sprite, at: CGPoint(x: leftSide ? 36 : size.width - 36, y: y * size.height), label: "Pie") {
                PieArt().frame(width: 56, height: 38).scaleEffect(grow).opacity(max(0, fade))
            }
        case .strut(let rtl, _, let pardoned, let lastTap):
            let span = size.width + 100
            let x = rtl ? size.width + 50 - t * span : -50 + t * span
            let hop = lastTap.map { now.timeIntervalSince($0) < 0.25 ? -12.0 : 0 } ?? 0
            let bob = abs(sin(age * 7)) * -3
            catchable(sprite, at: CGPoint(x: x, y: size.height - Self.tabBarClearance - 36 + hop + bob),
                      size: CGSize(width: 76, height: 68), label: pardoned ? "Pardoned turkey" : "Turkey, tap five times to pardon") {
                TurkeyArt(pardoned: pardoned).frame(width: 72, height: 64).scaleEffect(x: rtl ? -1 : 1, y: 1)
            }
        case .gust(let variant, let y, let spin):
            LeafArt(variant: variant).frame(width: 20, height: 20)
                .rotationEffect(.degrees(spin * t))
                .position(x: -30 + t * (size.width + 60), y: y * size.height + sin(t * .pi * 2) * 40)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        case .cheer(let text, let x, let y):
            Text(text)
                .font(.lexend(14, .semibold))
                .foregroundStyle(Brand.onBrand)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Brand.fill, in: Capsule())
                .fixedSize()
                .position(x: min(max(x, 70), size.width - 70), y: y - 24 - t * 30)
                .opacity(1 - t)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func falling(_ sprite: HarvestSprite, t: Double, size: CGSize) -> CGPoint {
        CGPoint(x: sprite.x * size.width + sin(t * .pi * 4) * sprite.sway, y: -30 + t * (size.height + 60))
    }

    /// A visitor that takes taps in a 44pt-or-bigger box around where it's drawn.
    private func catchable(_ sprite: HarvestSprite, at point: CGPoint, size: CGSize = CGSize(width: 48, height: 48),
                           label: String, @ViewBuilder art: () -> some View) -> some View {
        art()
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture { hit(sprite, at: point) }
            .position(point)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { hit(sprite, at: point) }
    }

    // MARK: Catching

    private func hit(_ sprite: HarvestSprite, at point: CGPoint) {
        switch sprite.kind {
        case .leaf:
            guard play.tally.tap(.leaves, bornAt: sprite.bornAt) else { return }
            game.remove(sprite.id)
            HarvestHaptics.catchOne()
            let leaves = season.countLeaf()
            game.cheer("+1 · \(leaves) leaves", at: point)
            if leaves % 25 == 0 { game.show("\(leaves) leaves caught. Keep raking.") }
        case .pie:
            guard play.tally.tap(.pies, bornAt: sprite.bornAt) else { return }
            game.remove(sprite.id)
            HarvestHaptics.catchOne()
            let pies = season.countPie()
            game.cheer("+1 · \(pies) pies", at: point)
            if pies % 10 == 0 { game.show("\(pies) pies eaten. Save some for the anchors.") }
        case .wishbone:
            guard play.tally.tap(.wishbones, bornAt: sprite.bornAt) else { return }
            game.remove(sprite.id)
            HarvestHaptics.success()
            game.cheer("Snap!", at: point)
            game.show("You got the bigger half. \(Self.wishes.randomElement() ?? "")")
        case .strut:
            guard let result = game.tapTurkey(sprite.id) else { return }
            guard result.pardoned else {
                HarvestHaptics.turkeyTap()
                if result.taps > 1 { game.cheer("\(result.taps)/\(HarvestSeason.pardonTaps)", at: point) }
                return
            }
            guard play.tally.tap(.pardons, bornAt: sprite.bornAt) else {
                game.unpardon(sprite.id)
                return
            }
            HarvestHaptics.success()
            game.cheer("Pardoned!", at: point)
            game.show("Turkey pardoned. By the power vested in the InFocus Portal, this turkey walks free.")
        case .gust, .cheer:
            return
        }
    }

    // MARK: Counter and notes

    @ViewBuilder private var counter: some View {
        if season.leaves + season.pies > 0 {
            Button {
                router.push(.seasonal(.leaderboard), on: .home)
            } label: {
                HStack(spacing: 8) {
                    Label("\(season.leaves)", systemImage: "leaf.fill")
                    Label("\(season.pies)", systemImage: "chart.pie.fill")
                }
                .labelStyle(CounterLabelStyle())
                .font(.mono(13, .medium))
                .monospacedDigit()
                .foregroundStyle(Brand.foreground)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(Brand.card.opacity(0.92), in: Capsule())
                .overlay(Capsule().stroke(Brand.line))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(season.leaves) leaves and \(season.pies) pies caught on this iPhone. Open the leaderboard.")
        }
    }

    @ViewBuilder private var noteView: some View {
        if let note = game.note {
            Text(note)
                .font(.lexend(14, .medium))
                .foregroundStyle(Brand.foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).stroke(Brand.green))
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

private struct CounterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(Brand.green).font(.system(size: 11))
            configuration.title
        }
    }
}

/// The giant turkey: rises from the bottom edge, looks around, pecks twice and sinks away.
/// It can't be tapped and never blocks Home.
private struct GiantTurkeyView: View {
    let start: Date
    let now: Date
    let size: CGSize

    var body: some View {
        let age = now.timeIntervalSince(start)
        let height = min(size.height * 0.7, size.width * 1.1)
        let rise = min(1, age / 1.2)
        let sink = max(0, min(1, (age - (HarvestPlay.giantLasts - 1.2)) / 1.2))
        let shown = rise - sink
        let pecking = [5.2, 5.9, 6.6].contains { abs(age - $0) < 0.18 }
        TurkeyArt()
            .frame(width: height * 1.1, height: height)
            .scaleEffect(x: -1, y: 1)
            .rotationEffect(.degrees(pecking ? -8 : sin(age * 1.5) * 2), anchor: .bottom)
            .position(x: size.width - height * 0.35, y: size.height + height * 0.5 - shown * height * 0.95)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

@MainActor
enum HarvestHaptics {
    static func catchOne() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func turkeyTap() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
