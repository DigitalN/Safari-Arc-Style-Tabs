// Which of Safari's windows are browser windows, the only ones the sidebar docks to. Kept apart from
// the Accessibility calls (SafariWindowReader reads the attributes) so the rule can be checked
// against recorded trees of Safari's windows (Tests/BrowserWindowChecks) without Safari.
//
// Safari has other windows too: Settings (every pane), About Safari, a detached Web Inspector,
// dialogs. Sheets aren't windows at all (their role is AXSheet). None of them can be docked to.

/// A window's close, full-screen or zoom button, as far as the rule cares.
nonisolated enum WindowButtonState: Equatable {
    case missing
    case enabled
    case disabled
    /// There, but Safari didn't say whether it's enabled.
    case unknown
}

/// What the rule goes by, read from one of Safari's windows. Nil is "not read" or "Safari didn't
/// say"; the rule treats both the same.
nonisolated struct WindowTraits: Equatable {
    /// `AXRole`.
    var role: String?
    /// `AXSubrole`. A minimized browser window reports `AXDialog`, not `AXStandardWindow` (Safari 27).
    var subrole: String?
    /// `AXIdentifier`: `SafariWindow?IsSecure=…&UUID=…` on every browser window, private ones
    /// included, from the moment it exists; `_NS:111` on Settings, whichever pane it shows. Not
    /// translated and not shown to anyone.
    var identifier: String?
    /// `AXMinimized`.
    var isMinimized: Bool?
    /// `AXFullScreen`.
    var isFullScreen: Bool?
    /// Only read for a window without an identifier (`BrowserWindowRule.needsButtons`).
    var fullScreenButton: WindowButtonState?
    /// Only read for a window without an identifier, and only when it has no full-screen button.
    var zoomButton: WindowButtonState?

    /// For the log: what the rule went by. Never the window's title, which is the page's. The
    /// identifier is cut at its first "?": a browser window's goes on with its UUID, and an
    /// identifier nobody has seen yet could go on with anything.
    var summary: String {
        let shownIdentifier: String
        switch identifier {
        case nil: shownIdentifier = "none"
        case ""?: shownIdentifier = "empty"
        case let identifier?: shownIdentifier = String(identifier.prefix { $0 != "?" }.prefix(48))
        }
        func shown(_ value: Bool?) -> String { value.map(String.init) ?? "nil" }
        func shown(_ button: WindowButtonState?) -> String { button.map { "\($0)" } ?? "unread" }
        return "role=\(role ?? "nil") subrole=\(subrole ?? "nil") identifier=\(shownIdentifier) minimized=\(shown(isMinimized)) fullScreen=\(shown(isFullScreen)) fullScreenButton=\(shown(fullScreenButton)) zoomButton=\(shown(zoomButton))"
    }
}

nonisolated enum BrowserWindowRule {
    static let windowRole = "AXWindow"
    static let standardWindowSubrole = "AXStandardWindow"
    /// What a browser window's identifier says before its first "?".
    static let browserIdentifier = "SafariWindow"

    /// Whether the window is one of Safari's browser windows (private ones included), minimized or
    /// not. Other code that needs to tell browser windows from Settings and the like, such as
    /// reading each browser window's profile, calls this.
    ///
    /// The identifier decides. A window with any other identifier isn't a browser window, whatever
    /// its buttons say: Settings has `_NS:111`, and a window nobody has recorded yet is safer left
    /// alone than docked to.
    ///
    /// Only a window without an identifier falls back to its buttons, as before identifiers were
    /// used: a standard window that's full screen, or whose full-screen button is enabled, is a
    /// browser window, and one whose full-screen button is disabled isn't. Safari now and then
    /// leaves the full-screen button out of a browser window for a few seconds, so a missing one
    /// doesn't count against a window, unless the window has a disabled zoom button instead, which
    /// is how Settings looks on Safari 27. A minimized window without an identifier isn't a
    /// browser window here, since it reports itself as a dialog.
    static func isBrowserWindow(_ window: WindowTraits) -> Bool {
        guard window.role == windowRole else { return false }
        if let identifier = window.identifier, !identifier.isEmpty {
            return isBrowserIdentifier(identifier)
        }
        guard window.subrole == standardWindowSubrole else { return false }
        if window.isFullScreen == true {
            return true
        }
        switch window.fullScreenButton ?? .missing {
        case .enabled, .unknown:
            return true
        case .disabled:
            return false
        case .missing:
            return window.zoomButton != .disabled
        }
    }

    /// Whether the sidebar can dock to the window: a browser window that isn't minimized.
    static func canDock(_ window: WindowTraits) -> Bool {
        isBrowserWindow(window) && window.isMinimized != true
    }

    /// Whether the rule needs the window's buttons, which cost more round trips to Safari. Never for
    /// a window with an identifier, which every recorded window of Safari's has.
    static func needsButtons(_ window: WindowTraits) -> Bool {
        window.role == windowRole && (window.identifier ?? "").isEmpty
            && window.subrole == standardWindowSubrole && window.isFullScreen != true
    }

    static func isBrowserIdentifier(_ identifier: String) -> Bool {
        identifier == browserIdentifier || identifier.hasPrefix(browserIdentifier + "?")
    }

    /// Picks the window to dock to:
    /// 1. Safari's focused window, if the sidebar can dock to it.
    /// 2. Otherwise its main window, if it can.
    /// 3. Otherwise the window it's docked to now, if it still can. So while Settings, a dialog or
    ///    any other window that isn't a browser window is in front, the sidebar stays with the
    ///    browser window it was docked to.
    /// 4. Otherwise the first in `windows` it can dock to. Safari lists its windows front to back.
    ///
    /// Every read is a round trip to Safari, so each is made only when the steps before it found
    /// nothing. `gaveUp` is asked after each look at a window; once it says Safari stopped
    /// answering, nothing more is read, and the answer is nil (the caller keeps what it had).
    static func choose<Window>(
        focused: Window?,
        main: () -> Window?,
        current: Window?,
        windows: () -> [Window],
        canDock: (Window) -> Bool,
        gaveUp: () -> Bool = { false }
    ) -> Window? {
        /// Whether to stop here: the window can be docked to, or Safari stopped answering.
        var chosen: Window?
        func settles(_ window: Window?) -> Bool {
            if let window, canDock(window) {
                chosen = window
            }
            return chosen != nil || gaveUp()
        }
        if settles(focused) || settles(main()) || settles(current) || windows().contains(where: settles) {
            return gaveUp() ? nil : chosen
        }
        return nil
    }
}
