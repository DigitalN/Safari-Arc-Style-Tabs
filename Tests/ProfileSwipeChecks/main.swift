import CoreGraphics
import Foundation

// Checks for swiping left or right on the sidebar to switch profiles (#72): which way a gesture goes from its first
// movement, where the page is while the fingers move, the halfway-or-flick rule when they lift, the ends (a little
// stretch, no switch, no wrap-around), and the profiles a swipe goes to, counted from the one highlighted. No AppKit:
// the rules in ProfileSwipeRules.swift. Which window comes forward is among the profile checks, and what the incoming
// page shows among the checks of the sidebar during a switch.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

// MARK: - The direction lock

do {
    var lock = SwipeDirectionLock()
    check(lock.add(dx: 1, dy: 1) == .undecided, "a point or two either way doesn't decide anything yet")
    check(lock.add(dx: 3, dy: 0) == .horizontal, "a gesture whose first movement is mostly sideways is a swipe")
    check(lock.add(dx: 0, dy: 40) == .horizontal, "and stays one when it turns vertical: it never scrolls")
    check(lock.horizontal == 4, "the page starts from the sideways movement so far")

    var vertical = SwipeDirectionLock()
    check(vertical.add(dx: 1, dy: -5) == .vertical, "one whose first movement is mostly up or down scrolls the lists")
    check(vertical.add(dx: 200, dy: 0) == .vertical, "and stays a scroll however far sideways it goes later: it never switches")

    var diagonal = SwipeDirectionLock()
    check(diagonal.add(dx: 4, dy: 4) == .vertical, "exactly diagonal scrolls, the common case")
    var left = SwipeDirectionLock()
    check(left.add(dx: -6, dy: 2) == .horizontal, "either way sideways")
}

// MARK: - Next and previous, counted from the profile highlighted

let a = UUID(), b = UUID(), c = UUID(), d = UUID()
let order = [a, b, c, d]

do {
    let middle = ProfileSwipeRules.neighbors(of: b, in: order)
    check(middle?.previous == a && middle?.next == c, "the profiles either side of the current one, in the bar's order")
    let first = ProfileSwipeRules.neighbors(of: a, in: order)
    check(first?.previous == nil && first?.next == b, "the first has nothing before it: no wrap-around")
    let last = ProfileSwipeRules.neighbors(of: d, in: order)
    check(last?.previous == c && last?.next == nil, "the last has nothing after it")
    check(ProfileSwipeRules.neighbors(of: nil, in: order) == nil, "no current profile (a private window): a swipe does nothing")
    check(ProfileSwipeRules.neighbors(of: UUID(), in: order) == nil, "nor for a profile the bar doesn't have")
    let single = ProfileSwipeRules.neighbors(of: a, in: [a])
    check(single?.previous == nil && single?.next == nil, "with one profile, both ways are ends")

    // Three quick swipes: each counts from the profile the last one is switching to (SafariProfiles.highlightedID is
    // the pending switch's), not the front window's, which hasn't changed yet.
    var highlighted = a
    for _ in 0..<3 {
        if let next = ProfileSwipeRules.neighbors(of: highlighted, in: order)?.next { highlighted = next }
    }
    check(highlighted == d, "three quick swipes move three profiles")
}

// MARK: - The page under the fingers

let width: CGFloat = 260

do {
    var swipe = ProfileSwipe(width: width, hasPrevious: true, hasNext: true)
    swipe.move(by: -50, at: 0)
    check(swipe.offset == -50 && swipe.incoming == .next, "fingers moving left move the page left, bringing in the next profile")
    swipe.move(by: 100, at: 0.1)
    check(swipe.offset == 50 && swipe.incoming == .previous, "back past where it started, the previous profile instead")
    swipe.move(by: 1000, at: 0.2)
    check(swipe.offset == width, "never more than one page: one profile per swipe, however far the drag goes")
}

// MARK: - Halfway or a flick

func swiped(_ distance: CGFloat, over duration: TimeInterval, steps: Int = 10, pause: TimeInterval = 0,
            hasPrevious: Bool = true, hasNext: Bool = true, cancelled: Bool = false) -> ProfileSwipe.Outcome {
    var swipe = ProfileSwipe(width: width, hasPrevious: hasPrevious, hasNext: hasNext)
    for step in 1...steps {
        swipe.move(by: distance / CGFloat(steps), at: duration * Double(step) / Double(steps))
    }
    return swipe.end(at: duration + pause, cancelled: cancelled)
}

do {
    check(swiped(-140, over: 1) == .switchTo(.next), "lifting slowly past halfway switches")
    check(swiped(140, over: 1) == .switchTo(.previous), "either way")
    check(swiped(-120, over: 1) == .springBack, "lifting slowly short of halfway springs back: nothing happens")
    check(swiped(-40, over: 0.05) == .switchTo(.next), "a quick flick switches well short of halfway")
    check(swiped(-8, over: 0.02) == .springBack, "but a flick has to have moved the page a little")
    check(swiped(-60, over: 0.1, pause: 0.3) == .springBack, "fingers that stopped before lifting aren't flicking")
    check(swiped(-140, over: 1, cancelled: true) == .springBack, "a cancelled gesture springs back")

    // Past halfway, then flicked back.
    var back = ProfileSwipe(width: width, hasPrevious: true, hasNext: true)
    back.move(by: -200, at: 0)
    for step in 1...5 { back.move(by: 12, at: 1 + Double(step) * 0.01) }
    check(back.offset < -width / 2 && back.end(at: 1.06) == .springBack, "past halfway but flicking back springs back")

    var speed = ProfileSwipe(width: width, hasPrevious: true, hasNext: true)
    speed.move(by: -10, at: 0)
    speed.move(by: -30, at: 0.05)
    check(abs(speed.speed(at: 0.05) + 800) < 1, "the speed is the fingers' last movement over the time it took")
}

// MARK: - At the ends

do {
    var first = ProfileSwipe(width: width, hasPrevious: false, hasNext: true)
    first.move(by: 100, at: 0)
    check(first.offset > 0 && first.offset < 40, "past the first profile the page stretches a little")
    first.move(by: 10_000, at: 0.1)
    check(first.offset < ProfileSwipe.stretchLimit(width: width) && first.offset > 40, "and never further than the limit, however far the fingers go")
    check(first.incoming == nil, "with nothing coming in")
    check(first.end(at: 0.2) == .springBack, "lifting there springs back and switches nothing")
    check(swiped(30, over: 0.03, hasPrevious: false) == .springBack, "nor does a flick")
    check(swiped(-200, over: 1, hasNext: false) == .springBack, "the same past the last profile")
    check(swiped(-200, over: 1, hasPrevious: false, hasNext: false) == .springBack
              && swiped(200, over: 1, hasPrevious: false, hasNext: false) == .springBack,
          "with one profile, neither way switches")

    let stretched = ProfileSwipe.stretched(80, width: width)
    check(abs(ProfileSwipe.unstretched(stretched, width: width) - 80) < 0.01,
          "a swipe that starts while the page springs back carries on from where it is")
    let resumed = ProfileSwipe(width: width, hasPrevious: false, hasNext: true, offset: stretched)
    check(abs(resumed.offset - stretched) < 0.01, "with no jump")
    let midSlide = ProfileSwipe(width: width, hasPrevious: true, hasNext: true, offset: -90)
    check(midSlide.offset == -90, "nor while the page is still sliding into place after a switch")
}

// MARK: - Sliding the rest of the way

do {
    var settle = SwipeSettle(offset: 120, velocity: -5000)
    var lowest: CGFloat = 120
    var time: TimeInterval = 0
    while !settle.isDone && time < 2 {
        settle.step(1.0 / 120)
        lowest = min(lowest, settle.offset)
        time += 1.0 / 120
    }
    check(settle.isDone && settle.offset == 0, "the page comes to rest in place")
    check(lowest >= -0.5, "without overshooting, however fast the fingers flicked: nothing past the page ever shows")
    check(time < 0.6, "in a fraction of a second")

    var long = SwipeSettle(offset: -100, velocity: 0)
    long.step(1)
    check(long.isDone, "a long frame can't throw it past its place")
}

// MARK: - The page slots

do {
    // Pages are profile names here; a switch's target is "to <profile>".
    typealias Slots = SwipeSlots<String, String>
    func neighbor(_ id: UUID, _ name: String) -> Slots.Neighbor { .init(profileID: id, target: "to \(name)") }
    func slot(at place: Int, in slots: Slots) -> Int? { (0..<3).first { slots.place(of: $0) == place } }

    // On B, swiping toward C: C's page is drawn only once the page moves its way.
    var slots = Slots()
    let inPlace = slot(at: 0, in: slots)!
    slots.begin(previous: neighbor(a, "A"), next: neighbor(c, "C"))
    check(slots.target(on: .next) == nil && slot(at: 1, in: slots) == nil, "a side's page isn't drawn until the page moves its way")
    var made = 0
    slots.reveal(.next) { target in made += 1; return "page " + target }
    slots.reveal(.next) { target in made += 1; return "page " + target }
    check(made == 1 && slots.target(on: .next) == "to C" && slot(at: 1, in: slots) != nil, "then once")
    let incoming = slot(at: 1, in: slots)!

    // The fingers lift: the switch to C starts.
    slots.switched(to: .next, outgoing: "B's page", outgoingProfile: b)
    check(slots.place(of: incoming) == 0, "the page that came in is in place, in the same slot, so it keeps its scroll position")
    check(slots.place(of: inPlace) == -1 && slots.content(of: inPlace) == "B's page", "B's page slides out to the left as it was, in its slot")
    check(slots.target(on: .previous) == nil, "and nothing switches to it while no swipe is going on")

    // A quick swipe back toward B, before B's page has finished sliding out (#72's review).
    slots.begin(previous: neighbor(b, "B"), next: neighbor(d, "D"))
    check(slots.place(of: inPlace) == -1 && slots.content(of: inPlace) == "B's page",
          "B's page, still sliding out, stays where it is, scrolled where it was")
    check(slots.target(on: .previous) == "to B", "and lifting toward it switches to B, as quick swipes in a row do")
    slots.reveal(.previous) { _ in "a new page" }
    check(slots.content(of: inPlace) == "B's page", "with no second page drawn over it")
    slots.switched(to: .previous, outgoing: "C's page", outgoingProfile: c)
    check(slots.place(of: inPlace) == 0 && slots.place(of: incoming) == 1 && slots.content(of: incoming) == "C's page",
          "B is in place again, and C's page slides out to the right")

    // A swipe on to another profile while a page slides out: the page of the profile left goes.
    slots.begin(previous: neighbor(a, "A"), next: neighbor(c, "C"))
    check(slots.target(on: .next) == "to C", "C's page, sliding out on the right, is C's: it stays, and can be swiped back to")
    var other = Slots()
    other.begin(previous: nil, next: neighbor(b, "B"))
    other.reveal(.next) { _ in "B's page" }
    other.switched(to: .next, outgoing: "A's page", outgoingProfile: a)
    other.begin(previous: neighbor(c, "C"), next: nil)
    check((0..<3).filter { other.place(of: $0) != nil } == [slot(at: 0, in: other)!],
          "a page sliding out that isn't the side's profile any more goes")
    check(other.target(on: .previous) == nil, "and the side's own page is drawn fresh once the page moves its way")
    other.reveal(.previous) { _ in "C's page" }
    check(other.target(on: .previous) == "to C", "and switches to C")

    // The page comes to rest.
    slots.settled()
    check((0..<3).compactMap { slots.place(of: $0) } == [0], "once the page is at rest, only it is drawn")
    check(slots.target(on: .previous) == nil && slots.target(on: .next) == nil, "and nothing beside it")
}

if failures > 0 {
    print("\(failures) swipe check(s) failed")
    exit(1)
}
print("swipe checks passed")
