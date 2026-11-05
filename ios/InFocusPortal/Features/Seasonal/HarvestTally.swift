import Foundation

/// Sends what this iPhone catches to the leaderboard (`POST api/thanksgiving`), a few seconds'
/// worth at a time, like the web's components/thanksgiving/harvest-tally.ts. Each catch keeps the
/// time it happened and how long its visitor had been on screen, which the Portal's cheat checks
/// read (src/lib/thanksgiving-guard.ts). A batch that fails for a passing reason (offline, the
/// Portal busy) goes back to the front of the queue with the same times, so if the first send did
/// land, the Portal drops the copy as a re-send instead of counting it twice. Only one send runs
/// at a time, so the timer and the app going to the background never send the same batch twice.
@MainActor
final class HarvestTally {
    /// How long catches wait before going out together.
    static let flushDelay: TimeInterval = 5
    /// After a failed send, the next try.
    static let retryDelay: TimeInterval = 15
    /// Beyond this much unsent play (a long time offline), the oldest catches are dropped.
    static let maxPending = 1_000
    /// `MAX_CATCHES_PER_BATCH`.
    static let maxBatch = 200
    /// Taps closer together than this aren't counted: the Portal rejects clicks under 90 ms apart
    /// as a script's, and two fingers can land that close.
    static let minGapMs: Int64 = 150

    private(set) var pending: [HarvestCatch] = []
    private var sending = false
    private var timer: Task<Void, Never>?
    private var lastTapAt: Int64?
    private let send: @Sendable (HarvestBatch) async throws -> Void
    private let clock: () -> Date
    private let delay: TimeInterval

    init(send: @escaping @Sendable (HarvestBatch) async throws -> Void,
         clock: @escaping () -> Date = Date.init, delay: TimeInterval = HarvestTally.flushDelay) {
        self.send = send
        self.clock = clock
        self.delay = delay
    }

    /// Counts a tapped catch whose visitor appeared at `bornAt`. Returns false (not counted) when
    /// the tap is too soon after the last one or the visitor too new, as the Portal would refuse it.
    @discardableResult
    func tap(_ kind: HarvestKind, bornAt: Date) -> Bool {
        let at = Self.ms(clock())
        let age = at - Self.ms(bornAt)
        if let last = lastTapAt, at - last < Self.minGapMs { return false }
        guard age >= Self.minAgeMs(kind) else { return false }
        lastTapAt = at
        queue(HarvestCatch(kind: kind, at: at, age: age))
        return true
    }

    /// Counts a giant turkey that walked in on its own (no tap, so no reaction time).
    func giantTurkey() {
        queue(HarvestCatch(kind: .giantTurkeys, at: Self.ms(clock()), age: nil))
    }

    /// Sends everything waiting now. Returns once it's saved, or put back to try again.
    func flush() async {
        timer?.cancel()
        timer = nil
        guard !sending else { return }
        sending = true
        defer { sending = false }
        while !pending.isEmpty {
            let batch = Array(pending.prefix(Self.maxBatch))
            pending.removeFirst(batch.count)
            do {
                try await send(HarvestBatch(catches: batch, sentAt: Self.ms(clock())))
            } catch {
                // A refused batch (the Portal said no) is dropped; anything queued meanwhile still goes.
                if Self.isRetryable(error) { pending = Array((batch + pending).suffix(Self.maxPending)) }
                if !pending.isEmpty { schedule(after: Self.retryDelay) }
                return
            }
        }
    }

    private func queue(_ entry: HarvestCatch) {
        pending = Array((pending + [entry]).suffix(Self.maxPending))
        if timer == nil, !sending { schedule(after: delay) }
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Forget the timer first: flush() cancels a pending timer, and this one is about to send.
            self.timer = nil
            await self.flush()
        }
    }

    /// Worth sending again later: offline, the Portal down or busy, or too many sends at once.
    static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? PortalError else { return true }
        switch error {
        case .offline: return true
        case .server(let status, _): return status == 0 || status == 429 || status >= 500
        default: return false
        }
    }

    /// The least time on screen the Portal accepts (`CATCH_RULES.minAgeMs`), with a little room.
    static func minAgeMs(_ kind: HarvestKind) -> Int64 {
        switch kind {
        case .pardons: 700
        case .giantTurkeys: 0
        default: 250
        }
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
