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
