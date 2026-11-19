import Foundation

// When silence from a copy of the extension counts against it (#45), kept apart from AppKit so the store
// checks can run it.
//
// Each copy sends a heartbeat when it has had nothing else delivered for `heartbeatInterval` (#80), and one
// that sends nothing for `allowance` counts as quiet: Side Tabs is probably off in its profile (#31). But a
// copy can be silent with nothing wrong, and silence then mustn't count:
//
// - **Holds.** While the Mac sleeps, its displays sleep, the screen is locked or the screen saver runs, the
//   session is switched away (fast user switching), or Safari is hidden, Safari holds its extensions'
//   timers back, or doesn't run at all. Nothing goes quiet during a hold, and when the last one ends,
//   every copy starts over with a whole allowance: its next heartbeat, as late as load can make it.
// - **Pauses the app asked for.** A hold that lasts `pauseAfter` has the copies asked to stop heartbeating
//   for `pauseLength`, and asked again every `pauseAfter` while it lasts (#80). The app tells them when the
//   hold ends, but commands can be lost, so a copy that missed it is silent until its pause runs out. Its
//   silence counts from then at the earliest.
// - **Listening starts.** When Side Tabs starts or Safari launches, no copy has spoken yet. Until they've
//   had the allowance, a profile with no live copy may only have a copy that hasn't spoken yet.
// - **Safari in the background.** Its timers can be held back then too, but that can't be told from Side
//   Tabs being turned off, so that silence counts. A copy that went quiet with Safari in the background
//   gets one more chance when Safari comes to the front (TabStore, "Copies of the extension").
//
// Time here is the Mac's awake time (`ProcessInfo.systemUptime`), which stops while it sleeps, so a night
// asleep never reads as a night of silence.

/// When the extension's copies could speak, and since when their silence counts.
nonisolated struct CopySilence: Equatable, Sendable {
    /// How long a copy goes without having anything delivered to the app before it sends a heartbeat
    /// (`HEARTBEAT_MS` in background.js).
    static let heartbeatInterval: TimeInterval = 10
    /// How long a copy can go without sending anything, while it could speak, before it counts as quiet. It
    /// sends something at least every `heartbeatInterval`, but under heavy load the extension has run up to
    /// 20 s late (#16–#22), and a reply can take 4 s: a heartbeat 30 s after the last message, and 10 s more.
    static let allowance: TimeInterval = 40
    /// How long a hold lasts before the copies are asked to stop heartbeating, and how often they're asked
    /// again while it lasts.
    static let pauseAfter: TimeInterval = 30
    /// How long each ask stops a copy's heartbeats for, unless the app says the hold has ended first. A little
    /// more than `pauseAfter`, so a long hold's asks overlap; not much more, since a copy that misses the end of
    /// the hold may be silent for up to this long after it.
    static let pauseLength: TimeInterval = 45

    /// Something that holds Safari's extension copies back, though nothing is wrong with them.
    enum Hold: String, CaseIterable, Comparable, Sendable {
        case asleep = "the Mac asleep"
        case displaysAsleep = "the displays asleep"
        case screenLocked = "the screen locked"
        case screenSaver = "the screen saver"
        case sessionInactive = "the session switched away"
        case safariHidden = "Safari hidden"

        static func < (a: Hold, b: Hold) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// What's holding the copies back now.
    private(set) var holds: Set<Hold> = []
    /// When the first of the current holds began, on the awake clock. Nil when there are none.
    private(set) var heldSince: TimeInterval?
    /// A copy's silence counts from here at the earliest: when listening started, or the last hold ended.
    private(set) var countsSince: TimeInterval
    /// When listening started (Side Tabs starting, Safari launching), while copies may not all have spoken
    /// yet. Nil once they've had the allowance.
    private(set) var waitingSince: TimeInterval?
    /// When the copies were last asked to stop heartbeating, on the awake clock. Nil if they never were.
    private(set) var pauseAskedAt: TimeInterval?

    /// Until when a copy may still be silent because it was asked to be, if it missed the end of the hold.
    var pausedUntil: TimeInterval? {
        pauseAskedAt.map { $0 + Self.pauseLength }
    }

    /// Whether the copies have been asked to stop heartbeating during the current hold.
    var pauseAskedDuringHold: Bool {
        guard let heldSince, let pauseAskedAt else { return false }
        return pauseAskedAt >= heldSince
    }

    /// When the copies should next be asked to stop heartbeating: `pauseAfter` into a hold, and every
    /// `pauseAfter` after that while it lasts. Nil when nothing holds them back.
    var nextPauseAsk: TimeInterval? {
        guard let heldSince else { return nil }
        return max(heldSince, pauseAskedAt ?? -.infinity) + Self.pauseAfter
    }

    /// The copies were asked at `now` to stop heartbeating for `pauseLength`.
    mutating func notePauseAsked(at now: TimeInterval) {
        pauseAskedAt = now
    }

    /// Listening starts at `now`, when Side Tabs starts.
    init(listeningSince now: TimeInterval) {
        countsSince = now
        waitingSince = now
    }

    /// Safari launched at `now`: its copies are all new, and none has spoken yet.
    mutating func startListening(at now: TimeInterval) {
        countsSince = now
        waitingSince = now
    }

    /// Takes what's holding the copies back now. Says whether that has just ended: then every copy's silence
    /// counts from `now`, and copies that hadn't had their chance when the hold began get a whole new one.
    mutating func update(holds new: Set<Hold>, at now: TimeInterval) -> Bool {
        let old = holds
        holds = new
        if old.isEmpty, !new.isEmpty {
            heldSince = now
            if let waiting = waitingSince, now - waiting >= Self.allowance {
                waitingSince = nil
            }
        } else if !old.isEmpty, new.isEmpty {
            heldSince = nil
            // A copy that missed the app saying so is silent until its pause runs out.
            let start = max(now, pausedUntil ?? now)
            countsSince = start
            if waitingSince != nil {
                waitingSince = start
            }
            return true
        }
        return false
    }

    /// How long a copy last heard at `lastHeard` has been silent in a way that counts: only since the last
    /// hold ended, or since `extraChance` (TabStore gives one when Safari comes to the front), and not at all
    /// during a hold.
    func silence(lastHeard: TimeInterval, extraChance: TimeInterval? = nil, at now: TimeInterval) -> TimeInterval {
        guard holds.isEmpty else { return 0 }
        return max(0, now - max(lastHeard, countsSince, extraChance ?? -.infinity))
    }

    /// When a copy last heard at `lastHeard` will count as quiet, if it says nothing more and nothing holds
    /// the copies back meanwhile. Nil during a hold, when no silence counts.
    func quietAt(lastHeard: TimeInterval, extraChance: TimeInterval? = nil) -> TimeInterval? {
        guard holds.isEmpty else { return nil }
        return max(lastHeard, countsSince, extraChance ?? -.infinity) + Self.allowance
    }

    /// Whether a copy last heard at `lastHeard` counts as quiet at `now`.
    func isQuiet(lastHeard: TimeInterval, extraChance: TimeInterval? = nil, at now: TimeInterval) -> Bool {
        silence(lastHeard: lastHeard, extraChance: extraChance, at: now) >= Self.allowance
    }

    /// Whether every copy has had its chance to speak since listening started. Until then, a profile with no
    /// live copy may only have a copy that hasn't spoken yet, and isn't offered to turn Side Tabs on (#33).
    func copiesHaveHadTheirChance(at now: TimeInterval) -> Bool {
        guard let waitingSince else { return true }
        return holds.isEmpty && now - waitingSince >= Self.allowance
    }

    /// How long until every copy has had its chance: zero once it has, nil during a hold, when it can't be
    /// told.
    func timeUntilCopiesHaveHadTheirChance(at now: TimeInterval) -> TimeInterval? {
        if copiesHaveHadTheirChance(at: now) {
            return 0
        }
        guard holds.isEmpty, let waitingSince else { return nil }
        return waitingSince + Self.allowance - now
    }

    /// The holds for the log, in a fixed order.
    static func describe(_ holds: Set<Hold>) -> String {
        holds.isEmpty ? "nothing" : holds.sorted().map(\.rawValue).joined(separator: ", ")
    }
}
