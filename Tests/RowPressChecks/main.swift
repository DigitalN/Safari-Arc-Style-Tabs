import CoreGraphics
import Foundation

// Checks for what a press on a sidebar row turns into (RowPress.swift). The SwiftUI gesture that
// feeds it needs the running app; these cover the rules it applies.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

func moved(_ dx: CGFloat, _ dy: CGFloat = 0) -> CGSize { CGSize(width: dx, height: dy) }

// MARK: - A press the row takes

do {
    var press = RowPress()
    var asked = 0
    func update(_ translation: CGSize) -> Bool {
        press.update(translation: translation) { asked += 1; return true }
    }
    check(!update(.zero), "the first update of a press is a press, not a drag")
    check(asked == 1, "the row is asked once whether it takes the press")
    check(!update(moved(1, 1)) && !update(moved(0, 3.9)), "a little movement isn't a drag")
    check(update(moved(0, 4)), "4 points is a drag")
    check(asked == 1, "and the row isn't asked again")
    check(update(moved(0, 30)), "it stays a drag")
    check(update(.zero), "it stays a drag when the pointer comes back to where it started")
    check(asked == 1, "still asked only once")
}

do {
    // Diagonal movement counts by distance.
    var press = RowPress()
    _ = press.update(translation: .zero) { true }
    check(!press.update(translation: moved(2.5, 2.5)) { true }, "2.5 + 2.5 is 3.5 points: not yet")
    check(press.update(translation: moved(3, 3)) { true }, "3 + 3 is 4.2 points: a drag")
}

do {
    // A press that begins already past the distance (the first update can carry movement).
    var press = RowPress()
    check(press.update(translation: moved(0, 10)) { true }, "a first update that is already far is a drag")
}

// MARK: - A press the row declines

do {
    // It landed on the close button, or the row is being renamed: no click, no drag.
    var press = RowPress()
    check(!press.update(translation: .zero) { false }, "a declined press is nothing")
    check(!press.update(translation: moved(0, 50)) { true }, "and never becomes a drag, however far the pointer goes")
    check(!press.update(translation: moved(0, 50)) { true }, "even if the row would take it now")
}

// MARK: - The next press starts fresh

do {
    // SwiftUI resets the gesture state when a press ends or is cancelled, so a new press is a new value.
    var press = RowPress()
    _ = press.update(translation: moved(0, 20)) { true }
    press = RowPress()
    var asked = false
    check(!press.update(translation: .zero) { asked = true; return true }, "a new press after a drag starts as a press")
    check(asked, "and asks the row again")
}

// MARK: - The round buttons

do {
    let button = CGRect(x: 200, y: 10, width: 20, height: 20)
    check(button.containsCircle(CGPoint(x: 210, y: 20)), "the middle is on the button")
    check(button.containsCircle(CGPoint(x: 219, y: 20)), "near the edge is on it")
    check(!button.containsCircle(CGPoint(x: 219, y: 29)), "a corner of its square isn't")
    check(!button.containsCircle(CGPoint(x: 230, y: 20)), "outside isn't")
    check(!CGRect.zero.containsCircle(.zero), "a button that isn't showing has no frame to hit")
}

if failures == 0 {
    print("row press checks passed")
} else {
    print("\(failures) row press check(s) failed")
    exit(1)
}
