import CoreGraphics

// Keeping the docked sidebar beside Safari's window without redoing work on every move (#85).
//
// While Safari's window is dragged, every move places the panel again. Moving it is all a move needs:
// its shadow and its place behind Safari's window stay as they are. Kept apart from AppKit so
// Tests/DockedPanelChecks can check them.

/// What the panel's shadow depends on. The shadow follows the outline the panel draws (it isn't opaque),
/// which changes with its size, with its style (attached to Safari's window, with corner fills, or
/// floating, rounded on both sides) and with the display's scale, never with where it is.
nonisolated struct PanelShadowShape: Equatable {
    var size: CGSize
    var attached: Bool
    var scale: CGFloat
}

nonisolated enum DockedPanelRules {
    /// Whether the window server has to work the shadow out again: the first time, and when its shape
    /// changed since. A move alone never does.
    static func needsNewShadow(_ shape: PanelShadowShape, last: PanelShadowShape?) -> Bool {
        shape != last
    }

    /// Whether `panel` is directly behind `window`, with nothing between them, in the window server's
    /// order of the windows on screen (front to back, every app and level). Only then can ordering the
    /// panel behind Safari's window again be skipped. Windows sit in bands by level, so anything between
    /// two normal windows is a normal window, and anything there (another app's window raised between
    /// them, Safari's window brought forward past another app's) means the panel goes back behind Safari.
    /// When either isn't in the list, it isn't.
    static func isDirectlyBehind(panel: Int, window: Int, frontToBack: [Int]) -> Bool {
        guard let index = frontToBack.firstIndex(of: window), index + 1 < frontToBack.count else { return false }
        return frontToBack[index + 1] == panel
    }
}

/// What ordering the panel behind Safari's window takes on one layout.
nonisolated enum PanelOrdering: Equatable {
    /// Order it behind Safari's window: it isn't on screen.
    case order
    /// Ask the window server for the windows' order, and order it only if it isn't directly behind.
    case check
    /// Nothing: Safari's window is being dragged.
    case skip
}

/// When the docked panel is ordered behind Safari's window again (#85).
///
/// While Safari's window is dragged or resized with the mouse button held, every move lays the sidebar out
/// again. Safari's window moving doesn't change what's stacked between it and the panel, and asking the
/// window server for every app's windows on each move costs about what skipping the re-order saves, so a
/// move during a drag does neither. Once the drag settles (the mouse button is up), the order is checked
/// once. Every other layout (Safari activated, its window focused or new, a change of Space, the health
/// look) checks it as before, and a panel that isn't on screen is always ordered in.
nonisolated struct PanelOrderingRule: Equatable {
    /// A drag skipped the check, so the drag's end has to make it.
    private(set) var checkWhenSettled = false

    /// For a layout of the docked panel. `dragging` is a move or resize of Safari's window with the mouse
    /// button held.
    mutating func layout(panelVisible: Bool, dragging: Bool) -> PanelOrdering {
        if !panelVisible {
            checkWhenSettled = false
            return .order
        }
        if dragging {
            checkWhenSettled = true
            return .skip
        }
        checkWhenSettled = false
        return .check
    }

    /// When a move or resize of Safari's window has settled with the mouse button up: the one check a
    /// drag put off, if it put one off.
    mutating func settled() -> PanelOrdering {
        guard checkWhenSettled else { return .skip }
        checkWhenSettled = false
        return .check
    }
}
