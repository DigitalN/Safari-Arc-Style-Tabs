import Foundation

/// One horizontal trackpad gesture produces at most one switch. Axis locking keeps
/// ordinary vertical scrolling and its momentum from accidentally changing spaces.
struct SpaceSwipe {
    enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var x = 0.0
    private var y = 0.0
    private var switched = false

    mutating func reset() { self = SpaceSwipe() }

    mutating func update(x dx: Double, y dy: Double, began: Bool, ended: Bool,
                         cancelled: Bool, momentum: Bool) -> (consume: Bool, direction: Int?) {
        if began { reset() }
        if momentum { return (axis == .horizontal, nil) }
        if cancelled {
            let consumed = axis == .horizontal
            reset()
            return (consumed, nil)
        }
        x += dx
        y += dy
        if axis == .undecided && max(abs(x), abs(y)) >= 8 {
            axis = abs(x) > abs(y) * 1.4 ? .horizontal : .vertical
        }
        var direction: Int?
        if axis == .horizontal && !switched && abs(x) >= 45 {
            direction = x < 0 ? 1 : -1
            switched = true
        }
        let consume = axis == .horizontal
        // Retain the axis through momentum; the next finger-down resets the gesture.
        if ended { switched = true }
        return (consume, direction)
    }
}
