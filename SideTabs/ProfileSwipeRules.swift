import CoreGraphics
import Foundation

// Swiping left or right on the sidebar to switch profiles (#72), kept apart from AppKit and SwiftUI so the checks
// can run it (Tests/ProfileSwipeChecks): which way a gesture goes, where the page is while the fingers move, and
// whether lifting them switches. The page follows the fingers, one profile per swipe, with no wrap-around.
//
// Offsets are in points, positive to the right: the page moves the way the scroll's content would
// (`scrollingDeltaX`), so it follows the user's scroll direction, as Safari's page swipe does. Moving right brings
// in the previous profile from the left; moving left, the next one from the right.

/// Which way a scroll gesture over the sidebar goes, from its first movement.
nonisolated struct SwipeDirectionLock: Equatable, Sendable {
    enum Axis: Equatable, Sendable {
        /// Not far enough yet to tell.
        case undecided
        /// Switches profiles, and never scrolls.
        case horizontal
        /// Scrolls the lists, as before, and never switches.
        case vertical
    }

    /// How far the fingers move before the direction is decided. A trackpad's first events are a point or two,
    /// often both ways at once.
    static let decideAfter: CGFloat = 4

    private(set) var axis = Axis.undecided
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0

    /// Adds a scroll event's movement; once decided, the direction stays for the rest of the gesture. Exactly
    /// diagonal counts as vertical: scrolling is the common case.
    @discardableResult
    mutating func add(dx: CGFloat, dy: CGFloat) -> Axis {
        guard axis == .undecided else { return axis }
        self.dx += dx
        self.dy += dy
        if (self.dx * self.dx + self.dy * self.dy).squareRoot() >= Self.decideAfter {
            axis = abs(self.dx) > abs(self.dy) ? .horizontal : .vertical
        }
        return axis
    }

    /// The horizontal movement so far: once horizontal, the page starts from it.
    var horizontal: CGFloat { dx }
}

/// The profiles a swipe can go to.
nonisolated enum ProfileSwipeRules {
    /// The profiles before and after `current` in the bar's order (Safari's), counted from the profile highlighted:
    /// the one a switch is already on its way to, else the front window's. Every profile in the bar counts. Nil
    /// when no profile is current (a private window): then a swipe does nothing.
    static func neighbors(of current: UUID?, in order: [UUID]) -> (previous: UUID?, next: UUID?)? {
        guard let current, let index = order.firstIndex(of: current) else { return nil }
        return (index > 0 ? order[index - 1] : nil, index + 1 < order.count ? order[index + 1] : nil)
    }
}

/// One horizontal swipe on the sidebar: the page under the fingers, and what lifting them does.
nonisolated struct ProfileSwipe: Equatable, Sendable {
    enum Side: Int, Equatable, Sendable {
        /// The previous profile's page, on the left: the page moves right to bring it in.
        case previous = -1
        /// The next profile's page, on the right.
        case next = 1
    }

    enum Outcome: Equatable, Sendable {
        /// Switch to the profile on that side; the page finishes sliding.
        case switchTo(Side)
        /// Nothing happens: the page springs back.
        case springBack
    }

    /// Past this many points a second in one direction, lifting the fingers is a flick.
    static let flickSpeed: CGFloat = 400
    /// A flick still has to have moved the page this far its way.
    static let flickDistance: CGFloat = 12
    /// How much of the fingers' last movement the speed is taken from.
    static let speedWindow: TimeInterval = 0.1

    /// The page's width: halfway is half of it, and the page never goes further than one page.
    let width: CGFloat
    let hasPrevious: Bool
    let hasNext: Bool
    /// How far the fingers have moved, positive to the right.
    private(set) var travel: CGFloat
    private var samples: [Sample] = []

    private struct Sample: Equatable, Sendable {
        let time: TimeInterval
        let delta: CGFloat
    }

    /// `offset`: where the page is when the fingers go down. Not 0 when a swipe starts while the last one's page is
    /// still sliding: it carries on from there.
    init(width: CGFloat, hasPrevious: Bool, hasNext: Bool, offset: CGFloat = 0) {
        self.width = max(width, 1)
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
        let toward = offset > 0 ? hasPrevious : hasNext
        travel = toward ? offset : Self.unstretched(offset, width: self.width)
    }

    mutating func move(by delta: CGFloat, at time: TimeInterval) {
        travel += delta
        samples.append(Sample(time: time, delta: delta))
        samples.removeAll { time - $0.time > 0.5 }
    }

    /// Where the page is: with the fingers, as far as one page toward a profile that's there, and stretched a little
    /// toward one that isn't (past the first or last profile).
    var offset: CGFloat {
        if travel > 0 {
            return hasPrevious ? min(travel, width) : Self.stretched(travel, width: width)
        }
        if travel < 0 {
            return hasNext ? max(travel, -width) : -Self.stretched(-travel, width: width)
        }
        return 0
    }

    /// The side whose page is coming in: the one the page has moved away from. Nil at rest, or past an end.
    var incoming: Side? {
        if offset > 0, hasPrevious { return .previous }
        if offset < 0, hasNext { return .next }
        return nil
    }

    /// How fast the fingers were moving at `time`, in points a second, positive to the right: their movement in the
    /// last tenth of a second. Fingers that stopped before lifting have no speed.
    func speed(at time: TimeInterval) -> CGFloat {
        let recent = samples.filter { time - $0.time <= Self.speedWindow }
        guard let first = recent.first else { return 0 }
        let span = max(min(Self.speedWindow, time - first.time), 1.0 / 60)
        return recent.reduce(0) { $0 + $1.delta } / span
    }

    /// The fingers lifted at `time`, like Safari's page swipe: past halfway, or a quick flick that way, switches,
    /// unless they were flicking back; otherwise the page springs back. Never past an end. A cancelled gesture
    /// always springs back.
    func end(at time: TimeInterval, cancelled: Bool = false) -> Outcome {
        guard !cancelled, let side = incoming else { return .springBack }
        let direction = CGFloat(-side.rawValue)
        let moved = offset * direction
        let along = speed(at: time) * direction
        if along <= -Self.flickSpeed {
            return .springBack
        }
        if along >= Self.flickSpeed && moved >= Self.flickDistance {
            return .switchTo(side)
        }
        return moved >= width / 2 ? .switchTo(side) : .springBack
    }

    // MARK: - Past an end

    /// How far the page stretches past the first or last profile, at most: a little.
    static func stretchLimit(width: CGFloat) -> CGFloat { width * 0.2 }

    /// The page's offset for `travel` points of finger movement past an end: less and less, never past the limit.
    static func stretched(_ travel: CGFloat, width: CGFloat) -> CGFloat {
        guard travel > 0 else { return 0 }
        let limit = stretchLimit(width: width)
        return limit * (1 - 1 / (travel / limit * 0.55 + 1))
    }

    /// The finger movement that stretches the page to `offset` (signed): for a swipe that starts while the page is
    /// still springing back.
    static func unstretched(_ offset: CGFloat, width: CGFloat) -> CGFloat {
        let limit = stretchLimit(width: width)
        let amount = min(abs(offset), limit * 0.999)
        guard amount > 0 else { return 0 }
        let travel = limit / 0.55 * (1 / (1 - amount / limit) - 1)
        return offset < 0 ? -travel : travel
    }
}

/// The page sliding the rest of the way after the fingers lift: into place after a switch, or back after one that
/// didn't. A critically damped spring, which starts at the fingers' speed and never overshoots, so nothing past the
/// page ever shows.
nonisolated struct SwipeSettle: Equatable, Sendable {
    /// How quickly it settles: about a quarter of a second.
    static let stiffness: CGFloat = 20

    private(set) var offset: CGFloat
    private(set) var velocity: CGFloat

    init(offset: CGFloat, velocity: CGFloat) {
        self.offset = offset
        // Faster than this toward the target would carry the page past it.
        let most = Self.stiffness * abs(offset)
        let toward = offset > 0 ? -velocity : velocity
        self.velocity = toward > 0 ? (offset > 0 ? -1 : 1) * min(toward, most) : 0
    }

    var isDone: Bool { abs(offset) < 0.5 && abs(velocity) < 5 }

    /// Moves `dt` seconds on, toward 0. Exact for the spring, so a long frame can't make it overshoot.
    mutating func step(_ dt: TimeInterval) {
        let w = Self.stiffness
        let t = CGFloat(max(dt, 0))
        let decay = CGFloat(exp(Double(-w * t)))
        let b = velocity + w * offset
        let next = (offset + b * t) * decay
        velocity = (b - w * (offset + b * t)) * decay
        offset = next
        if isDone {
            offset = 0
            velocity = 0
        }
    }
}
