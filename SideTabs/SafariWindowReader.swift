import AppKit
@preconcurrency import ApplicationServices
import os

/// Private but long-stable API (used by most window managers) that maps an AX window to
/// its window server id, so the panel can be ordered directly above Safari's window.
@_silgen_name("_AXUIElementGetWindow")
nonisolated private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// What the sidebar needs to know about the Safari window it's docked to, as of the last time
/// it was read. Coordinates are AX coordinates: origin top-left of the main display, y down.
nonisolated struct WindowReading {
    var frame: CGRect?
    var title: String?
    var isFullScreen = false
    /// The window server's id for the window.
    var number: Int?
    /// Bottom edge of Safari's toolbar and tab bar. Only read in full screen, and in normal
    /// windows while the sidebar hides automatically: the overlay has to start below it.
    var toolbarBottom: CGFloat?
}

/// Reads Safari's windows through the Accessibility API, off the main thread.
///
/// Every Accessibility call waits for Safari's main thread, which can be busy for seconds. The
/// sidebar's own main thread asks for these reads every second and after every window event, so
/// it must never be the one waiting: SafariTracker asks this reader to do it and uses the
/// answer when it arrives. When Safari doesn't answer in time, the outcome says so, and the
/// tracker keeps what it knew, so a slow Safari can't make the sidebar hide or jump.
nonisolated final class SafariWindowReader: @unchecked Sendable {
    struct Outcome {
        /// The browser window to dock to.
        var window: AXUIElement?
        /// Safari's focused window, if this read found out.
        var focusedWindow: AXUIElement?
        var focusedWindowKnown = false
        var reading = WindowReading()
        /// Safari didn't answer in time; the tracker should keep what it already knew.
        var keepPrevious = false
    }

    let queue = DispatchQueue(label: "com.digitaln.sidetabs.accessibility-read", qos: .userInitiated)
    /// How long any one read waits for Safari. After a timeout a read gives up on the rest.
    private let query = AXQuery(timeout: 0.5)
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "tracker")

    // Only used on `queue`.
    private var observer: AXObserver?
    private var refcon: UnsafeMutableRawPointer?
    private var observedWindow: AXUIElement?
    private var lastWindowDescription = ""
    private var lastRejectedDescription = ""

    static let windowNotifications = DockedWindowNotifications.names

    // MARK: - Notifications

    /// Starts reporting on the docked window's notifications to `observer`. Call on `queue`.
    func use(observer: AXObserver, refcon: UnsafeMutableRawPointer) {
        self.observer = observer
        self.refcon = refcon
        observedWindow = nil
    }

    /// Stops watching. Call on `queue`.
    func stopWatching() {
        watch(nil)
        observer = nil
        refcon = nil
    }

    private func watch(_ window: AXUIElement?) {
        if let observedWindow, let window, CFEqual(observedWindow, window) {
            return
        }
        if let observer, let observedWindow {
            AXUIElementSetMessagingTimeout(observedWindow, query.timeout)
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(observer, observedWindow, name as CFString)
            }
        }
        observedWindow = window
        if let observer, let refcon, let window {
            AXUIElementSetMessagingTimeout(window, query.timeout)
            for name in Self.windowNotifications {
                AXObserverAddNotification(observer, window, name as CFString, refcon)
            }
        }
    }

    /// Asks Safari to report the application-wide notifications to `observer`. Returns the
    /// names Safari refused. Call on `queue`.
    func register(_ names: [String], on application: AXUIElement, observer: AXObserver, refcon: UnsafeMutableRawPointer) -> [String] {
        AXUIElementSetMessagingTimeout(application, query.timeout)
        var failures: [String] = []
        for name in names {
            let error = AXObserverAddNotification(observer, application, name as CFString, refcon)
            if error != .success {
                failures.append("\(name)=\(error.rawValue)")
            }
        }
        return failures
    }

    // MARK: - Reading

    /// Picks the window to dock to (when `full`) and reads its frame and the rest. `current` is
    /// the window docked to now and `previous` what was read from it. `toolbarInWindows` also reads
    /// where the toolbar ends when the window isn't full screen.
    func read(application: AXUIElement, current: AXUIElement?, previous: WindowReading, full: Bool, toolbarInWindows: Bool = false) -> Outcome {
        query.clearTimedOut()
        var outcome = Outcome()
        var window = current
        if full {
            let choice = chooseWindow(application, current: current)
            if query.timedOut {
                outcome.keepPrevious = true
                return outcome
            }
            window = choice.window
            outcome.focusedWindow = choice.focused
            outcome.focusedWindowKnown = true
        }
        guard let window else {
            return outcome
        }
        let sameWindow = current.map { CFEqual($0, window) } ?? false
        let (reading, complete) = readGeometry(window, previous: sameWindow ? previous : WindowReading(), toolbarInWindows: toolbarInWindows)
        if !complete && !sameWindow {
            // A window whose frame Safari wouldn't give can't be docked to yet; stay where we are.
            outcome.keepPrevious = true
            outcome.focusedWindowKnown = false
            return outcome
        }
        outcome.window = window
        outcome.reading = reading
        watch(window)
        return outcome
    }

    /// Reads everything but the window itself. Stops at the first read Safari doesn't answer,
    /// keeping what was read so far and the previous value of the rest.
    private func readGeometry(_ window: AXUIElement, previous: WindowReading, toolbarInWindows: Bool) -> (reading: WindowReading, complete: Bool) {
        var reading = previous
        func step<Value>(_ body: () -> Value, _ assign: (inout WindowReading, Value) -> Void) -> Bool {
            query.clearTimedOut()
            let value = body()
            if query.timedOut { return false }
            assign(&reading, value)
            return true
        }
        guard step({ frame(of: window) }, { $0.frame = $1 }),
              step({ query.string(window, kAXTitleAttribute) }, { $0.title = $1 }),
              step({ query.bool(window, "AXFullScreen") ?? false }, { $0.isFullScreen = $1 }) else {
            return (reading, false)
        }
        if reading.number == nil {
            reading.number = windowNumber(of: window)
        }
        if reading.isFullScreen || toolbarInWindows, let frame = reading.frame {
            guard step({ toolbarBottom(of: window, windowFrame: frame) }, { $0.toolbarBottom = $1 }) else {
                return (reading, false)
            }
        } else {
            reading.toolbarBottom = nil
        }
        return (reading, true)
    }

    /// Writes a frame, then reads the window back. Call on `queue`.
    func setFrame(_ frame: CGRect, of window: AXUIElement, previous: WindowReading, toolbarInWindows: Bool = false) -> WindowReading {
        query.clearTimedOut()
        var position = frame.origin
        var size = frame.size
        if let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size) {
            // Position, size, position: shrinking can be blocked until the window has moved,
            // and a constrained resize can nudge the origin.
            query.set(window, kAXPositionAttribute, positionValue)
            query.set(window, kAXSizeAttribute, sizeValue)
            query.set(window, kAXPositionAttribute, positionValue)
        }
        query.clearTimedOut()
        return readGeometry(window, previous: previous, toolbarInWindows: toolbarInWindows).reading
    }

    // MARK: - Choosing the window

    /// Picks the browser window to dock to: the focused one if it's a browser window,
    /// otherwise keeps the current one, otherwise the frontmost browser window.
    private func chooseWindow(_ application: AXUIElement, current: AXUIElement?) -> (window: AXUIElement?, focused: AXUIElement?) {
        let focused = query.element(application, kAXFocusedWindowAttribute)
        if query.timedOut {
            return (nil, nil)
        }
        if let focused, isBrowserWindow(focused) {
            return (focused, focused)
        }
        if let main = query.element(application, kAXMainWindowAttribute), isBrowserWindow(main) {
            return (main, focused)
        }
        if let focused {
            let description = describe(focused)
            if description != lastRejectedDescription {
                lastRejectedDescription = description
                log.notice("focused window isn't a browser window: \(description, privacy: .public)")
            }
        }
        if let current, isBrowserWindow(current) {
            return (current, focused)
        }
        let windows = query.elements(application, kAXWindowsAttribute)
        if let first = windows.first(where: isBrowserWindow) {
            return (first, focused)
        }
        if query.timedOut {
            return (nil, focused)
        }
        let description = windows.isEmpty ? "Safari reports no windows" : windows.map(describe).joined(separator: "; ")
        if description != lastWindowDescription {
            lastWindowDescription = description
            log.notice("no browser window among: \(description, privacy: .public)")
        }
        return (nil, focused)
    }

    private func describe(_ window: AXUIElement) -> String {
        let button = query.element(window, kAXFullScreenButtonAttribute)
        let buttonState = button.map { query.bool($0, kAXEnabledAttribute).map { $0 ? "enabled" : "disabled" } ?? "unknown" } ?? "missing"
        // Without the window's title: it is the page's, and the log keeps no browsing history.
        return "role=\(query.string(window, kAXRoleAttribute) ?? "nil") subrole=\(query.string(window, kAXSubroleAttribute) ?? "nil") minimized=\(query.bool(window, kAXMinimizedAttribute).map(String.init) ?? "nil") fullScreenButton=\(buttonState)"
    }

    /// Browser windows are standard windows that can go full screen. Safari's Settings
    /// window has a disabled full-screen button, which is how it's told apart. Safari now and
    /// then leaves the button out of a browser window for a few seconds, so a missing button
    /// doesn't count against a window.
    private func isBrowserWindow(_ window: AXUIElement) -> Bool {
        guard query.string(window, kAXRoleAttribute) == kAXWindowRole,
              query.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              query.bool(window, kAXMinimizedAttribute) != true else { return false }
        if query.bool(window, "AXFullScreen") ?? false {
            return true
        }
        guard let button = query.element(window, kAXFullScreenButtonAttribute) else { return true }
        return query.bool(button, kAXEnabledAttribute) ?? true
    }

    // MARK: - Geometry

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = query.value(element, kAXPositionAttribute),
              let sizeValue = query.value(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func windowNumber(of window: AXUIElement) -> Int? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { return nil }
        return Int(id)
    }

    /// Bottom edge (AX coordinates) of Safari's toolbar and tab bar, from the window's direct
    /// children only so it stays fast. Nil if Safari doesn't report them (e.g. a hidden
    /// full-screen toolbar).
    private func toolbarBottom(of window: AXUIElement, windowFrame: CGRect) -> CGFloat? {
        var bottom: CGFloat?
        for child in query.elements(window, kAXChildrenAttribute) {
            guard let role = query.string(child, kAXRoleAttribute),
                  role == kAXToolbarRole || role == kAXTabGroupRole,
                  let childFrame = frame(of: child),
                  childFrame.height < 200,
                  childFrame.minY < windowFrame.minY + 200 else { continue }
            bottom = max(bottom ?? childFrame.maxY, childFrame.maxY)
        }
        return bottom
    }
}
