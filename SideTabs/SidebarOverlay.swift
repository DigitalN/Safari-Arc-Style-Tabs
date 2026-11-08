import CoreGraphics
import Foundation

// Where the sidebar goes when it isn't docked beside Safari's window, and when it slides out over
// the page and away again. Kept apart from AppKit so the rules can be checked without Safari
// (Tests/SidebarOverlayChecks): DockController reads Safari's window and the pointer, feeds them in,
// and moves the panel.

/// How the sidebar sits by the Safari window it follows.
nonisolated enum SidebarPlacement: Equatable {
    /// Beside the window, which is narrowed or moved to make room.
    case docked
    /// Hidden until the pointer or the toolbar button brings it out over the page.
    case overlay(OverlayPlace)

    /// Full screen always gets the overlay at the screen's edge, whatever the setting says. A normal
    /// window gets one at its own left edge only when "Hide sidebar automatically" is on.
    static func choose(fullScreen: Bool, hidesAutomatically: Bool) -> SidebarPlacement {
        if fullScreen {
            return .overlay(.fullScreen)
        }
        return hidesAutomatically ? .overlay(.window) : .docked
    }
}

nonisolated enum OverlayPlace: Equatable {
    /// Safari is full screen: the sidebar comes out from the screen's left edge.
    case fullScreen
    /// A normal window, with the sidebar hiding automatically: it comes out from the window's left
    /// edge, and Safari keeps its whole window.
    case window
}

/// Where the pointer has to be to bring the sidebar out. Its edges count as inside.
nonisolated struct RevealStrip: Equatable {
    /// Nil when the strip reaches as far left as the pointer can go.
    var minX: CGFloat?
    var maxX: CGFloat
    var minY: CGFloat
    var maxY: CGFloat

    func contains(_ point: CGPoint) -> Bool {
        if let minX, point.x < minX {
            return false
        }
        return point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

/// Where the overlay's panel goes, and the strip that brings it out, in AppKit screen coordinates
/// (origin at the bottom left of the main display, y up). Worked out again whenever Safari's window
/// moves, changes size or is replaced by another, so the strip follows the window and bringing the
/// sidebar out never has to wait for a layout.
nonisolated struct OverlayLayout: Equatable {
    var panel: CGRect
    var strip: RevealStrip

    /// Space between the panel and the edges around it.
    static let inset: CGFloat = 8
    /// Safari's full-screen toolbar is about 52 pt tall. The panel never starts higher than this
    /// below the top, even if Safari doesn't say where its toolbar ends.
    static let minimumToolbar: CGFloat = 60
    static let minimumHeight: CGFloat = 200
    /// How far the strip along a window's left edge reaches out of the window and into it. A
    /// window's edge doesn't stop the pointer the way the screen's edge does, so the strip is a
    /// little wider than the screen's.
    static let stripOutside: CGFloat = 4
    static let stripInside: CGFloat = 4

    /// Full screen: the panel runs down the screen's left side below Safari's toolbar, and the
    /// strip is the screen's left edge, all the way up.
    ///
    /// `toolbarBottom` is where Safari's toolbar and tab bar end, in Accessibility coordinates
    /// (y down from the top of the main display), if Safari said. `mainHeight` is the main
    /// display's height, which converts between the two.
    static func fullScreen(screen: CGRect, toolbarBottom: CGFloat?, mainHeight: CGFloat, width: CGFloat) -> OverlayLayout {
        let top = belowToolbar(areaTop: screen.maxY, toolbarBottom: toolbarBottom, mainHeight: mainHeight)
        return OverlayLayout(
            panel: panelFrame(left: screen.minX, bottom: screen.minY, top: top, width: width),
            strip: RevealStrip(minX: nil, maxX: screen.minX + 2, minY: screen.minY, maxY: screen.maxY)
        )
    }

    /// A normal window: the panel runs down the window's left side below its toolbar, over the
    /// page, and the strip is the window's left edge beside the page. Only the part of the window
    /// inside `visible` counts (the visible frame of the screen that has most of the window), so a
    /// window pushed partly off the screen, or under the Dock, still has its strip and panel where
    /// they can be reached and seen.
    static func window(frame: CGRect, visible: CGRect, toolbarBottom: CGFloat?, mainHeight: CGFloat, width: CGFloat) -> OverlayLayout {
        let shown = frame.intersection(visible)
        let area = shown.isNull || shown.isEmpty ? frame : shown
        let top = min(belowToolbar(areaTop: frame.maxY, toolbarBottom: toolbarBottom, mainHeight: mainHeight), area.maxY)
        return OverlayLayout(
            panel: panelFrame(left: area.minX, bottom: area.minY, top: top, width: width),
            strip: RevealStrip(minX: area.minX - stripOutside, maxX: area.minX + stripInside, minY: area.minY, maxY: top)
        )
    }

    private static func panelFrame(left: CGFloat, bottom: CGFloat, top: CGFloat, width: CGFloat) -> CGRect {
        let bottom = bottom + inset
        let top = top - inset
        return CGRect(x: left + inset, y: bottom, width: width, height: max(top - bottom, minimumHeight)).integral
    }

    /// The AppKit y of the bottom of Safari's toolbar and tab bar, never less than
    /// `minimumToolbar` below `areaTop` (the AppKit y of the top of the screen or window).
    private static func belowToolbar(areaTop: CGFloat, toolbarBottom: CGFloat?, mainHeight: CGFloat) -> CGFloat {
        let areaTopFromAbove = mainHeight - areaTop
        return mainHeight - max(toolbarBottom ?? 0, areaTopFromAbove + minimumToolbar)
    }
}

/// Whether the overlay is out, and what puts it away. DockController asks it about the pointer 30
/// times a second while there is an overlay, and when the toolbar button or its shortcut is used.
nonisolated struct OverlayReveal: Equatable {
    enum Action: Equatable {
        case none
        /// Show the panel, at once.
        case reveal
        /// Fade the panel out.
        case conceal
    }

    /// How far outside the panel the pointer can stray before the sidebar slides away.
    static let margin: CGFloat = 24

    private(set) var isRevealed = false
    /// Brought out with the toolbar button or its shortcut, rather than by the pointer.
    private(set) var isPinned = false
    /// The pointer has been over the sidebar since it came out.
    private(set) var pointerVisited = false

    /// One look at the pointer.
    ///
    /// - `safariInFront`: Safari is the active app. The sidebar only ever shows over Safari.
    /// - `holding`: something needs the sidebar to stay out wherever the pointer is: a rename, a
    ///   context menu or drag in progress, a mouse button held down.
    /// - `mayReveal`: asked only when the pointer has reached the strip, for checks too slow to make
    ///   30 times a second, such as whether Safari's window is on the Space being shown.
    mutating func poll(
        pointer: CGPoint,
        strip: RevealStrip,
        panel: CGRect,
        safariInFront: Bool,
        holding: Bool,
        mayReveal: () -> Bool = { true }
    ) -> Action {
        guard safariInFront else {
            return isRevealed ? conceal() : .none
        }
        guard isRevealed else {
            return strip.contains(pointer) && mayReveal() ? reveal() : .none
        }
        let inside = panel.insetBy(dx: -Self.margin, dy: -Self.margin).contains(pointer)
        if inside {
            pointerVisited = true
        }
        // Brought out with the shortcut: it stays until the pointer has been over it and left.
        if isPinned && !pointerVisited {
            return .none
        }
        return holding || inside ? .none : conceal()
    }

    /// The toolbar button or its shortcut: bring the sidebar out, or put it away.
    mutating func toggle() -> Action {
        if isRevealed {
            return conceal()
        }
        isPinned = true
        return reveal()
    }

    private mutating func reveal() -> Action {
        isRevealed = true
        pointerVisited = false
        return .reveal
    }

    private mutating func conceal() -> Action {
        isRevealed = false
        isPinned = false
        return .conceal
    }
}
