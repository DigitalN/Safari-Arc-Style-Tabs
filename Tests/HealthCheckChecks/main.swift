import Foundation

// Checks for when the dock looks again at Safari's window for changes macOS doesn't announce, how often, and
// what each look reads (HealthCheck.swift, #78). The reads themselves, the timer and what Safari answers need
// the running app; these cover the rules.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

typealias Cadence = HealthCheck.Cadence

func cadence(sidebar: Bool = true, running: Bool = true, holds: Set<CopySilence.Hold> = [], front: Bool = true) -> Cadence {
    HealthCheck.cadence(sidebarVisible: sidebar, safariRunning: running, holds: holds, safariInFront: front)
}

// MARK: - When the looks run

check(cadence() == .safariInFront, "sidebar on, Safari running and in front, nothing held: every second")
// With another app in front no look runs either: a look would have to ask Safari to see anything its own
// notifications don't already report (#78 acceptance: no Accessibility calls into Safari while it's behind).
check(!cadence(front: false).isRunning, "with another app in front: no looks")
check(cadence(front: false) == .off("Safari in the background"), "and the log says why")

// Nothing to keep in place: no timer at all, so no Accessibility calls into Safari and no wakeups.
for front in [true, false] {
    check(!cadence(sidebar: false, front: front).isRunning, "sidebar turned off: no looks (Safari in front: \(front))")
    check(!cadence(running: false, front: front).isRunning, "Safari not running: no looks (in front: \(front))")
    for hold in CopySilence.Hold.allCases {
        check(!cadence(holds: [hold], front: front).isRunning, "\(hold.rawValue): no looks (in front: \(front))")
    }
}
check(!cadence(holds: [.screenLocked, .displaysAsleep]).isRunning, "several holds at once: no looks")
check(!cadence(sidebar: false, running: false, holds: [.asleep], front: false).isRunning, "everything off: no looks")

// The reason is for the log, and says which case it is.
if case .off(let reason) = cadence(sidebar: false) {
    check(reason.contains("sidebar"), "the log says the sidebar is off: \(reason)")
} else {
    check(false, "sidebar off is .off")
}
if case .off(let reason) = cadence(running: false) {
    check(reason.contains("not running"), "the log says Safari isn't running: \(reason)")
} else {
    check(false, "Safari not running is .off")
}
if case .off(let reason) = cadence(holds: [.screenLocked]) {
    check(reason == CopySilence.describe([.screenLocked]), "the log names the hold: \(reason)")
} else {
    check(false, "a hold is .off")
}
// The sidebar turned off comes first: it's the one the user chose.
check(cadence(sidebar: false, running: false, holds: [.asleep]) == .off("sidebar turned off"), "sidebar off is the reason given first")

// MARK: - How often

check(Cadence.safariInFront.interval == 1, "every second while Safari is in front")
check(Cadence.off("x").interval == nil, "no interval when off")
check(Cadence.safariInFront.tolerance >= 0.1, "tolerance is at least 10% of the interval")
check(Cadence.safariInFront.tolerance <= 0.5, "but not so much the looks drift")

// MARK: - What a look reads

func look(_ cadence: Cadence, since: Int = 0, due: Bool = false, window: Bool = true) -> HealthCheck.Read? {
    HealthCheck.look(cadence: cadence, looksSinceFullRead: since, fullReadDue: due, hasWindow: window)
}

check(look(.off("x")) == nil, "no look when off")
check(look(.off("x"), due: true, window: false) == nil, "not even when a full read is due")
check(look(.off("Safari in the background"), since: 5, due: true) == nil, "nor while Safari is behind")

check(look(.safariInFront, since: 0) == .geometry, "right after a full read: only the geometry")
check(look(.safariInFront, since: 0, due: true) == .full, "a full read when one is due")
check(look(.safariInFront, since: 0, window: false) == .full, "a full read when no window is known")
check(look(.safariInFront, since: HealthCheck.fullReadEvery - 1) == .full, "a full read every \(HealthCheck.fullReadEvery) looks")

// MARK: - The schedule, look after look

// Within about two seconds while Safari is in front, every case the looks are for is caught: the geometry
// ones at the next look, a missed window switch at the next full read.
do {
    var schedule = HealthCheck.Schedule()
    var reads: [HealthCheck.Read] = []
    for _ in 0..<10 {
        if let read = schedule.next(cadence: .safariInFront, hasWindow: true) {
            reads.append(read)
        }
    }
    check(reads.first == .full, "the first look after starting picks the window: \(reads)")
    check(reads.contains(.geometry), "not every look picks the window: \(reads)")
    var longest = 0
    var run = 0
    for read in reads {
        run = read == .full ? 0 : run + 1
        longest = max(longest, run)
    }
    let worst = Double(longest + 1) * ((Cadence.safariInFront.interval ?? 99) + Cadence.safariInFront.tolerance)
    check(worst <= 2.5, "a missed window switch is caught within about 2 s: \(worst) s, reads \(reads)")
    check((Cadence.safariInFront.interval ?? 99) + Cadence.safariInFront.tolerance <= 1.5, "the geometry cases within about 1 s")
    check(reads.count == 10, "every tick is a look while Safari is in front")
    check(reads.filter { $0 == .full }.count <= 5, "at most half the looks pick the window: \(reads)")
}

do {
    // In front, then a hold, then in front again: the first look after picks the window.
    var schedule = HealthCheck.Schedule()
    _ = schedule.next(cadence: .safariInFront, hasWindow: true)
    _ = schedule.next(cadence: .safariInFront, hasWindow: true)
    check(schedule.next(cadence: .off("the screen locked"), hasWindow: true) == nil, "no look during a hold")
    schedule.resume()
    check(schedule.next(cadence: .safariInFront, hasWindow: true) == .full, "after a hold, the first look picks the window")
    check(schedule.next(cadence: .safariInFront, hasWindow: true) == .geometry, "then only the geometry")
}

do {
    // Safari goes behind and comes back to the front. Behind is an .off cadence, so coming back starts the looks
    // again (DockController resumes the schedule when the cadence goes from not running to running), and the
    // first look picks the window: whatever changed while it was behind and unannounced is seen.
    let behind = cadence(front: false)
    let front = cadence(front: true)
    check(!behind.isRunning && front.isRunning, "behind to front starts the looks, so the schedule resumes")
    var schedule = HealthCheck.Schedule()
    _ = schedule.next(cadence: front, hasWindow: true)
    check(schedule.next(cadence: behind, hasWindow: true) == nil, "behind: no look, so nothing is read from Safari")
    schedule.resume()
    check(schedule.next(cadence: front, hasWindow: true) == .full, "back in front: the first look picks the window")
}

if failures == 0 {
    print("health check checks passed")
} else {
    print("\(failures) health check check(s) failed")
    exit(1)
}
