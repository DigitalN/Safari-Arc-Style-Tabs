import Foundation
import CoreGraphics

/// Pure geometry in AppKit screen coordinates. Windowed drawers stay inside Safari's
/// visible content; fullscreen retains the existing screen-edge activation behavior.
struct SidebarOverlayLayout: Equatable {
    var frame: CGRect
    var trigger: CGRect

    static func make(window: CGRect, screen: CGRect, toolbarBottom: CGFloat?, width: CGFloat,
                     fullScreen: Bool) -> Self? {
        let bounds = window.intersection(screen)
        guard !bounds.isNull, bounds.width > 16, bounds.height > 76 else { return nil }
        let inset: CGFloat = 8
        let top = min(bounds.maxY, window.maxY - 60, toolbarBottom ?? (window.maxY - 60)) - inset
        let bottom = bounds.minY + inset
        guard top - bottom >= 40 else { return nil }
        let frame = CGRect(x: bounds.minX + inset, y: bottom,
                           width: min(width, bounds.width - 2 * inset), height: top - bottom).integral
        let trigger = CGRect(x: bounds.minX, y: fullScreen ? bounds.minY : frame.minY,
                             width: 4, height: fullScreen ? bounds.height : frame.height)
        return Self(frame: frame, trigger: trigger)
    }
}

/// A delayed hide avoids flicker while crossing into a row/menu. Explicit opening
/// stays visible until the pointer visits the drawer, then follows normal hover rules.
struct SidebarAutoHide {
    enum Action { case none, reveal, conceal }
    private(set) var revealed = false
    private var awaitingPointer = false
    private var hideAt: TimeInterval?
    static let hideDelay: TimeInterval = 0.22

    mutating func reset() { self = SidebarAutoHide() }
    mutating func toggle() -> Action {
        if revealed { reset(); return .conceal }
        revealed = true; awaitingPointer = true; hideAt = nil
        return .reveal
    }
    mutating func update(now: TimeInterval, atEdge: Bool, inside: Bool, foreground: Bool,
                         editing: Bool, tracking: Bool) -> Action {
        guard foreground else {
            let wasRevealed = revealed
            reset()
            return wasRevealed ? .conceal : .none
        }
        if !revealed {
            guard atEdge else { return .none }
            revealed = true; awaitingPointer = false; hideAt = nil
            return .reveal
        }
        if inside { awaitingPointer = false }
        if inside || atEdge || editing || tracking || awaitingPointer {
            hideAt = nil
            return .none
        }
        if hideAt == nil { hideAt = now + Self.hideDelay }
        guard now >= hideAt! else { return .none }
        reset()
        return .conceal
    }
}
