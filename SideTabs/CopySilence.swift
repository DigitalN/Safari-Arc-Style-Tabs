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
//   for `pauseLength`, and asked again every `pauseRenewal` while it lasts (#80). The app tells them when
//   the hold ends, but commands can be lost, so a copy that missed it is silent until its pause runs out.
//   Counted per copy: one heard from since the hold ended has had the word (or its pause ran out), and its
//   silence counts as usual; one not heard from since counts from the end of its pause at the earliest. A
//   copy that's still paused says so in every message, and for how long (`heartbeatsPausedFor`).
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
    /// How long a hold lasts before the copies are asked to stop heartbeating, so a short one asks nothing.
    static let pauseAfter: TimeInterval = 30
    /// How long each ask stops a copy's heartbeats for, unless the app says the hold has ended first: the most
    /// the extension allows (`PAUSE_LIMIT_MS` in background.js), so a long hold asks rarely.
    static let pauseLength: TimeInterval = 300
    /// How often the copies are asked again while a hold lasts: a minute before the last ask runs out, so a
    /// late timer or a slow command doesn't let them start heartbeating in between.
    static let pauseRenewal: TimeInterval = 240

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
    /// When the copies were last asked to stop heartbeating, on the awake clock. Nil if they never were, or
    /// since Safari launched (its copies are new).
    private(set) var pauseAskedAt: TimeInterval?
    /// When the last hold ended. Nil before the first.
    private(set) var lastHoldEnd: TimeInterval?
    /// Until when a copy not heard from since the last hold ended may still be silent because it was asked to
    /// be and missed the word that the hold had ended. Nil when no ask outlasted the hold.
    private(set) var missedResumeUntil: TimeInterval?

    /// Until when a copy asked to stop heartbeating at the last ask may still be silent.
    var pausedUntil: TimeInterval? {
        pauseAskedAt.map { $0 + Self.pauseLength }
    }

    /// Whether the copies have been asked to stop heartbeating during the current hold.
    var pauseAskedDuringHold: Bool {
        guard let heldSince, let pauseAskedAt else { return false }
        return pauseAskedAt >= heldSince
    }

    /// When the copies should next be asked to stop heartbeating: `pauseAfter` into a hold, and every
    /// `pauseRenewal` after that while it lasts. Nil when nothing holds them back.
    var nextPauseAsk: TimeInterval? {
        guard let heldSince else { return nil }
        if pauseAskedDuringHold, let pauseAskedAt {
            return pauseAskedAt + Self.pauseRenewal
        }
        return heldSince + Self.pauseAfter
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

    /// Safari launched at `now`: its copies are all new, none has spoken yet, and none was asked to pause.
    mutating func startListening(at now: TimeInterval) {
        countsSince = now
        waitingSince = now
        pauseAskedAt = nil
        missedResumeUntil = nil
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
            countsSince = now
            lastHoldEnd = now
            // A copy that missed the app saying so is silent until its pause runs out.
            missedResumeUntil = pausedUntil.flatMap { $0 > now ? $0 : nil }
            if waitingSince != nil {
                // Copies that haven't spoken yet haven't been heard from since, either.
                waitingSince = max(now, missedResumeUntil ?? now)
            }
            return true
        }
        return false
    }

    /// Since when silence from a copy last heard at `lastHeard` counts: since the last hold ended, or since
    /// `extraChance` (TabStore gives one when Safari comes to the front), and not before a pause it may still
    /// be in has run out: `pausedUntil`, as its last message said, or, if it hasn't been heard from since the
    /// last hold ended, the end of the pause it may have missed the word on.
    private func countsFrom(lastHeard: TimeInterval, extraChance: TimeInterval?, pausedUntil: TimeInterval?) -> TimeInterval {
        var from = max(lastHeard, countsSince, extraChance ?? -.infinity, pausedUntil ?? -.infinity)
        if let missedResumeUntil, let lastHoldEnd, lastHeard < lastHoldEnd {
            from = max(from, missedResumeUntil)
        }
        return from
    }

    /// How long a copy last heard at `lastHeard` has been silent in a way that counts (`countsFrom`), and not
    /// at all during a hold.
    func silence(lastHeard: TimeInterval, extraChance: TimeInterval? = nil, pausedUntil: TimeInterval? = nil, at now: TimeInterval) -> TimeInterval {
        guard holds.isEmpty else { return 0 }
        return max(0, now - countsFrom(lastHeard: lastHeard, extraChance: extraChance, pausedUntil: pausedUntil))
    }

    /// When a copy last heard at `lastHeard` will count as quiet, if it says nothing more and nothing holds
    /// the copies back meanwhile. Nil during a hold, when no silence counts.
    func quietAt(lastHeard: TimeInterval, extraChance: TimeInterval? = nil, pausedUntil: TimeInterval? = nil) -> TimeInterval? {
        guard holds.isEmpty else { return nil }
        return countsFrom(lastHeard: lastHeard, extraChance: extraChance, pausedUntil: pausedUntil) + Self.allowance
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
