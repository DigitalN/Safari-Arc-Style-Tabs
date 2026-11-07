import CoreGraphics
import Foundation

// What a left-button press on a sidebar row turns into. Kept apart from SwiftUI so the rules can
// be checked without the app: SidebarDrag.swift feeds it the gesture's updates.

/// One press on a row, from mouse-down to mouse-up. A row does two things with it: it reacts at
/// once (switching to the tab, on mouse-down), and when the pointer moves far enough the press
/// becomes a drag to reorder instead. Both come from one gesture, so neither can keep the other
/// from starting.
nonisolated struct RowPress: Equatable {
    /// How far the pointer has to move before the press is a drag, in points.
    static let dragDistance: CGFloat = 4

    private enum Phase {
        /// No update seen yet.
        case idle
        /// The row declined this press (it landed on a button, or the row is being renamed).
        case declined
        /// The row took the press; the pointer hasn't moved far.
        case pressed
        /// The pointer moved far enough: a drag. It stays one even if the pointer comes back.
        case dragging
    }

    private var phase = Phase.idle

    /// Feeds in one update of the gesture. `takes` is asked once, on the first update, whether
    /// the row wants this press at all. Returns whether the press is a drag now.
    mutating func update(translation: CGSize, takes: () -> Bool) -> Bool {
        if phase == .idle {
            phase = takes() ? .pressed : .declined
        }
        if phase == .pressed, hypot(translation.width, translation.height) >= Self.dragDistance {
            phase = .dragging
        }
        return phase == .dragging
    }
}

nonisolated extension CGRect {
    /// Whether `point` is inside the circle that fills this (square) rect, which is the shape
    /// of the row's icon buttons.
    func containsCircle(_ point: CGPoint) -> Bool {
        !isEmpty && hypot(point.x - midX, point.y - midY) <= min(width, height) / 2
    }
}
