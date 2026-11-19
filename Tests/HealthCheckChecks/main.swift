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
check(cadence(front: false) == .safariBehind, "with another app in front: the slow looks")

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
if let behind = Cadence.safariBehind.interval {
    check(behind >= 5, "at most every 5 s while Safari is behind: \(behind)")
} else {
    check(false, "the slow looks have an interval")
}
check(Cadence.off("x").interval == nil, "no interval when off")
for running in [Cadence.safariInFront, .safariBehind] {
    let interval = running.interval ?? 0
    check(running.tolerance >= interval * 0.1, "tolerance is at least 10% of the interval for \(running.summary)")
    check(running.tolerance <= interval * 0.5, "but not so much the looks drift for \(running.summary)")
}

// MARK: - What a look reads

func look(_ cadence: Cadence, since: Int = 0, due: Bool = false, window: Bool = true) -> HealthCheck.Look? {
    HealthCheck.look(cadence: cadence, looksSinceFullRead: since, fullReadDue: due, hasWindow: window)
}

check(look(.off("x")) == nil, "no look when off")
check(look(.off("x"), due: true, window: false) == nil, "not even when a full read is due")

// Safari behind: never picks the window, never reads the bars or copies the window list, never attaches.
for since in 0..<20 {
    for due in [false, true] {
        guard let behind = look(.safariBehind, since: since, due: due) else {
            check(false, "a look runs while Safari is behind")
            continue
        }
        check(behind.read == .geometry, "Safari behind: only the docked window's frame and the like (since \(since), due \(due))")
        check(!behind.readsBars, "Safari behind: Safari's bars aren't read")
        check(!behind.checksStacking, "Safari behind: the window list isn't copied")
        check(!behind.attaches, "Safari behind: attaching again is the tracker's job")
    }
}
check(look(.safariBehind, window: false)?.read == HealthCheck.Read.none, "Safari behind with no window: nothing is read from Safari")
check(look(.safariBehind, due: true, window: false)?.read == HealthCheck.Read.none, "not even when a full read is due")

// Safari in front: everything the looks are for.
if let front = look(.safariInFront, since: 0) {
    check(front.readsBars, "Safari in front: its bars are read (#35)")
    check(front.checksStacking, "Safari in front: what's between Safari's window and the sidebar is checked")
    check(front.attaches, "Safari in front: attaches if needed")
} else {
    check(false, "a look runs while Safari is in front")
}
check(look(.safariInFront, since: 0)?.read == .geometry, "right after a full read: only the geometry")
check(look(.safariInFront, since: 0, due: true)?.read == .full, "a full read when one is due")
check(look(.safariInFront, since: 0, window: false)?.read == .full, "a full read when no window is known")
check(look(.safariInFront, since: HealthCheck.fullReadEvery - 1)?.read == .full, "a full read every \(HealthCheck.fullReadEvery) looks")

// MARK: - The schedule, look after look

// Within about two seconds while Safari is in front, every case the looks are for is caught: the geometry
// ones at the next look, a missed window switch at the next full read.
do {
    var schedule = HealthCheck.Schedule()
    var reads: [HealthCheck.Read] = []
    for _ in 0..<10 {
        reads.append(schedule.next(cadence: .safariInFront, hasWindow: true)?.read ?? .none)
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
    check(reads.filter { $0 == .full }.count <= 5, "at most half the looks pick the window: \(reads)")
}

do {
    // Behind, then the looks stop (a hold), then start again: the first look after picks the window.
    var schedule = HealthCheck.Schedule()
    _ = schedule.next(cadence: .safariInFront, hasWindow: true)
    _ = schedule.next(cadence: .safariBehind, hasWindow: true)
    check(schedule.next(cadence: .off("the screen locked"), hasWindow: true) == nil, "no look during a hold")
    schedule.resume()
    check(schedule.next(cadence: .safariInFront, hasWindow: true)?.read == .full, "after a hold, the first look picks the window")
    check(schedule.next(cadence: .safariInFront, hasWindow: true)?.read == .geometry, "then only the geometry")
}

do {
    // A full read due while Safari is behind waits for Safari to come to the front.
    var schedule = HealthCheck.Schedule()
    schedule.resume()
    check(schedule.next(cadence: .safariBehind, hasWindow: true)?.read == .geometry, "behind: no full read, even when due")
    check(schedule.fullReadDue, "it stays due")
    check(schedule.next(cadence: .safariInFront, hasWindow: true)?.read == .full, "in front: the due full read")
    check(!schedule.fullReadDue, "and it's done")
}

if failures == 0 {
    print("health check checks passed")
} else {
    print("\(failures) health check check(s) failed")
    exit(1)
}
