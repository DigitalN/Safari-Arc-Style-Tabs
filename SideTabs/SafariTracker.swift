import AppKit
import ApplicationServices
import os.log

/// Private but long-stable window server calls (also used by most window managers) that
/// say which Spaces a window is on and which Space each display is showing.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?

/// Watches Safari through the Accessibility API: which browser window is in front, where
/// it is, and whether it's full screen, minimized or hidden.
///
/// Nothing here waits for Safari on the main thread. Safari answers Accessibility calls from its
/// own main thread, which can be busy for seconds, and the sidebar's main thread has clicks to
/// handle. The reads happen in SafariWindowReader; this class keeps the last answer (`window`
/// and `reading`) and updates it when a new one arrives, so a slow Safari just means the
/// sidebar goes on with what it last knew.
final class SafariTracker {
    static let safariBundleID = "com.apple.Safari"

    enum Event {
        case focusChanged
        case moved
        case resized
        case visibilityChanged
        case launched
        case terminated
        /// A background read found a different window to dock to than the one known before.
        case windowChanged
        /// The docked window's title changed (`reading` has the new one). Nothing else did.
        case titleChanged
    }

    var onEvent: ((Event) -> Void)?
    /// Called when the docked window changes, to another window or to none (SafariProfiles reads the
    /// new one's profile).
    var onWindowChange: (() -> Void)?
    /// Called with each Accessibility notification from Safari, after the tracker has handled it.
    var onNotification: ((String, AXUIElement) -> Void)?

    private(set) var app: NSRunningApplication?
    /// The browser window the sidebar docks to.
    private(set) var window: AXUIElement? {
        didSet {
            switch (oldValue, window) {
            case let (old?, new?) where CFEqual(old, new): break
            case (nil, nil): break
            default: onWindowChange?()
            }
        }
    }
    /// What was last read from `window`: its frame, title and so on.
    private(set) var reading = WindowReading()
    /// Also read where Safari's toolbar ends in normal windows, not only in full screen: the sidebar
    /// that hides automatically comes out below it.
    var readsToolbarInWindows = false

    private var appElement: AXUIElement?
    private var observer: AXObserver?
    /// The window Safari last reported as focused, kept up to date by its notifications and
    /// the periodic refresh, so a click doesn't have to ask Safari on every mouse-down.
    private var focusedWindow: AXUIElement?
    /// The Accessibility requests a click makes of Safari, which run off the main thread.
    private let clickActions = ClickActions()
    /// Reads Safari's windows off the main thread.
    private let windowReader = SafariWindowReader()
    /// Switches tabs by pressing their buttons in Safari's tab bar, off the main thread.
    private let tabBar = TabBarPresser()
    private var workspaceTokens: [NSObjectProtocol] = []
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "tracker")

    /// Window reads in flight. One runs at a time; requests made meanwhile are merged into one
    /// that starts when it finishes, so a burst of window events costs Safari two reads at most.
    private struct RefreshRequest {
        var full: Bool
        var completions: [(Bool) -> Void]
    }
    private var refreshRunning = false
    private var queuedRefresh: RefreshRequest?
    /// Bumped when attaching or detaching, so a read that started before can be told apart.
    private var attachment = 0

    private static let appNotifications = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
    ]

    var isTrusted: Bool { AccessibilityAccess.isGranted }

    var isSafariFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.safariBundleID
    }

    var isAttached: Bool { observer != nil }

    // MARK: - Lifecycle

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (SafariTracker, NSRunningApplication?) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self, app)
                }
            }
            workspaceTokens.append(token)
        }

        observe(NSWorkspace.didLaunchApplicationNotification) { tracker, app in
            guard let app, app.bundleIdentifier == Self.safariBundleID else { return }
            tracker.app = app
            // Give Safari a moment to create its accessibility hierarchy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                tracker.attach(app)
                tracker.refreshWindow { _ in tracker.onEvent?(.launched) }
            }
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { tracker, app in
            guard app?.bundleIdentifier == Self.safariBundleID else { return }
            tracker.detach()
            tracker.app = nil
            tracker.onEvent?(.terminated)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { tracker, app in
            if app?.bundleIdentifier == Self.safariBundleID {
                tracker.refreshWindow { _ in tracker.onEvent?(.focusChanged) }
            } else {
                tracker.onEvent?(.focusChanged)
            }
        }
        observe(NSWorkspace.didHideApplicationNotification) { tracker, _ in tracker.onEvent?(.visibilityChanged) }
        observe(NSWorkspace.didUnhideApplicationNotification) { tracker, _ in tracker.onEvent?(.visibilityChanged) }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { tracker, _ in
            tracker.refreshWindow { _ in tracker.onEvent?(.visibilityChanged) }
        }

        attachIfNeeded()
    }

    /// Attaches to a running Safari once Accessibility access is granted. Safe to call often.
    func attachIfNeeded() {
        if app == nil || app?.isTerminated == true {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.safariBundleID).first
        }
        guard let app, !app.isTerminated else { return }
        if observer == nil {
            attach(app)
        }
        if window == nil {
            refreshWindow { [weak self] changed in
                if changed {
                    self?.onEvent?(.windowChanged)
                }
            }
        }
    }

    private func attach(_ app: NSRunningApplication) {
        detach()
        self.app = app
        guard isTrusted else { return }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<SafariTracker>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated {
                tracker.handle(name, element: element)
            }
        }
        let createError = AXObserverCreate(app.processIdentifier, callback, &created)
        guard createError == .success, let created else {
            log.error("AXObserverCreate failed: \(createError.rawValue)")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        appElement = element
        observer = created
        attachment += 1

        // Safari answers these requests from its main thread, which is the last thing to be free
        // right after it launches, so they're made off ours. If Safari refuses all of them it
        // isn't ready yet; let go, and the next attempt starts again.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let registration = Registration(observer: created, refcon: refcon)
        let pid = app.processIdentifier
        let names = Self.appNotifications
        let reader = windowReader
        let epoch = attachment
        reader.queue.async { [weak self, log] in
            reader.use(observer: registration.observer, refcon: registration.refcon)
            let failures = reader.register(names, on: element, observer: registration.observer, refcon: registration.refcon)
            log.notice("attached to Safari pid \(pid); notification failures: \(failures.isEmpty ? "none" : failures.joined(separator: ", "), privacy: .public)")
            guard failures.count >= names.count else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let self, self.attachment == epoch {
                        self.detach()
                    }
                }
            }
        }
    }

    /// An observer and the pointer its callback gets back, which can cross to the reader's queue.
    private struct Registration: @unchecked Sendable {
        let observer: AXObserver
        let refcon: UnsafeMutableRawPointer
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        attachment += 1
        observer = nil
        appElement = nil
        window = nil
        reading = WindowReading()
        focusedWindow = nil
        clickActions.forgetMenuItem()
        let reader = windowReader
        reader.queue.async { reader.stopWatching() }
    }

    private func handle(_ name: String, element: AXUIElement) {
        switch name {
        case kAXWindowMovedNotification:
            if let window, CFEqual(window, element) {
                refreshWindow(full: false) { [weak self] _ in self?.onEvent?(.moved) }
            }
        case kAXWindowResizedNotification:
            if let window, CFEqual(window, element) {
                refreshWindow(full: false) { [weak self] _ in self?.onEvent?(.resized) }
            }
        case _ where DockedWindowNotifications.isTitleChange(name):
            // Reported by every window, but only the docked one matters, and only its title: the
            // read is the same as for a move, and what follows is not a layout.
            if let window, CFEqual(window, element) {
                refreshWindow(full: false) { [weak self] _ in self?.onEvent?(.titleChanged) }
            }
        case kAXApplicationHiddenNotification, kAXApplicationShownNotification:
            onEvent?(.visibilityChanged)
        case kAXWindowMiniaturizedNotification, kAXUIElementDestroyedNotification:
            refreshWindow { [weak self] _ in self?.onEvent?(.visibilityChanged) }
        default:
            refreshWindow { [weak self] _ in self?.onEvent?(.focusChanged) }
        }
        onNotification?(name, element)
    }

    // MARK: - Choosing the window

    /// Looks again at which browser window to dock to, and at where it is, without waiting for
    /// Safari on this thread. `completion` runs on the main thread when the answer is in,
    /// with whether the docked window changed. If Safari doesn't answer in time, nothing
    /// changes and `completion` is told so.
    ///
    /// Only one read runs at a time. Requests made while it does are merged into the next.
    /// `full: false` only looks at the docked window's frame and the like, which is all a move or
    /// resize needs.
    func refreshWindow(full: Bool = true, then completion: ((Bool) -> Void)? = nil) {
        let request = RefreshRequest(full: full || window == nil, completions: completion.map { [$0] } ?? [])
        guard !refreshRunning else {
            if var queued = queuedRefresh {
                queued.full = queued.full || request.full
                queued.completions += request.completions
                queuedRefresh = queued
            } else {
                queuedRefresh = request
            }
            return
        }
        beginRefresh(request)
    }

    private func beginRefresh(_ request: RefreshRequest) {
        guard let appElement else {
            // Not attached: there is no window.
            let changed = window != nil
            window = nil
            reading = WindowReading()
            focusedWindow = nil
            request.completions.forEach { $0(changed) }
            return
        }
        refreshRunning = true
        let epoch = attachment
        let current = window
        let previous = reading
        let reader = windowReader
        let toolbarInWindows = readsToolbarInWindows
        reader.queue.async { [weak self] in
            let outcome = reader.read(application: appElement, current: current, previous: previous, full: request.full, toolbarInWindows: toolbarInWindows)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finish(request, outcome: outcome, epoch: epoch)
                }
            }
        }
    }

    private func finish(_ request: RefreshRequest, outcome: SafariWindowReader.Outcome, epoch: Int) {
        refreshRunning = false
        var changed = false
        if epoch == attachment, !outcome.keepPrevious {
            if outcome.focusedWindowKnown {
                focusedWindow = outcome.focusedWindow
            }
            switch (window, outcome.window) {
            case let (old?, new?): changed = !CFEqual(old, new)
            case (nil, nil): changed = false
            default: changed = true
            }
            window = outcome.window
            reading = outcome.reading
        }
        request.completions.forEach { $0(changed) }
        if let next = queuedRefresh {
            queuedRefresh = nil
            beginRefresh(next)
        }
    }

    // MARK: - Window geometry (AX coordinates: origin top-left of the main display, y down)

    // These answer from the last read of the docked window, never by asking Safari.

    func frame(of window: AXUIElement) -> CGRect? {
        cachedReading(of: window)?.frame
    }

    func title(of window: AXUIElement) -> String? {
        cachedReading(of: window)?.title
    }

    func isFullScreen(_ window: AXUIElement) -> Bool {
        cachedReading(of: window)?.isFullScreen ?? false
    }

    func windowNumber(of window: AXUIElement) -> Int? {
        cachedReading(of: window)?.number
    }

    /// Bottom edge of Safari's toolbar and tab bar in full screen, if Safari reported them.
    func toolbarBottom(of window: AXUIElement) -> CGFloat? {
        cachedReading(of: window)?.toolbarBottom
    }

    private func cachedReading(of element: AXUIElement) -> WindowReading? {
        guard let window, CFEqual(window, element) else { return nil }
        return reading
    }

    /// Moves and resizes the docked window, off the main thread, then reads it back.
    /// `completion` runs on the main thread with the frame the window ended up with.
    func setFrame(_ frame: CGRect, of window: AXUIElement, then completion: ((CGRect?) -> Void)? = nil) {
        let previous = reading
        let reader = windowReader
        let toolbarInWindows = readsToolbarInWindows
        reader.queue.async { [weak self] in
            let reading = reader.setFrame(frame, of: window, previous: previous, toolbarInWindows: toolbarInWindows)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let self, let current = self.window, CFEqual(current, window) {
                        self.reading = reading
                    }
                    completion?(reading.frame)
                }
            }
        }
    }

    /// The same, but waits. For when the app is quitting and won't be around for the answer.
    func setFrameAndWait(_ frame: CGRect, of window: AXUIElement) {
        let previous = reading
        let reader = windowReader
        reader.queue.sync {
            _ = reader.setFrame(frame, of: window, previous: previous)
        }
    }

    /// Whether the window is on a Space being shown. Full-screen windows have their own
    /// Space, and so do full-screen videos, which Safari shows in a separate window.
    ///
    /// Compares Spaces rather than asking whether the window is on screen: while a swipe
    /// between Spaces is in progress, windows on both Spaces count as on screen, even if
    /// the swipe is then taken back.
    func isOnActiveSpace(_ window: AXUIElement) -> Bool {
        guard let number = windowNumber(of: window) else { return true }
        return isOnActiveSpace(windowNumber: number)
    }

    /// The same check for any window, such as the sidebar's own.
    func isOnActiveSpace(windowNumber number: Int) -> Bool {
        let connection = CGSMainConnectionID()
        let allSpaces: Int32 = 0x7 // current, other and user Spaces
        let windowSpaces = CGSCopySpacesForWindows(connection, allSpaces, [number] as CFArray)?
            .takeRetainedValue() as? [Int] ?? []
        let displays = CGSCopyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] ?? []
        let shownSpaces = displays.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int }
        if !windowSpaces.isEmpty && !shownSpaces.isEmpty {
            return windowSpaces.contains(where: shownSpaces.contains)
        }
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]]
        return info?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    /// Puts the cursor in Safari's own address bar, like pressing ⌘L, once Safari is in front.
    func openLocation() {
        focusSafari { [weak self] in
            guard let self, let appElement, let pid = app?.processIdentifier else { return }
            // Part of the click that brought Safari forward, so it runs after that click's
            // raise, and is dropped if the user has clicked something else since.
            clickActions.pressOpenLocation(application: appElement, processIdentifier: pid, ticket: clickActions.currentTicket())
        }
    }

    /// Brings Safari and the docked window to the front.
    ///
    /// macOS ignores ordinary activation requests from apps that aren't in front, and Side
    /// Tabs never is (its sidebar doesn't take focus). So the usual request, which costs
    /// nothing, goes out at once on the main thread, together with the Accessibility ones
    /// (raise the window, make Safari frontmost). If Safari still isn't in front shortly
    /// after, LaunchServices is asked to open it, which brings an already-running app forward.
    ///
    /// The Accessibility calls wait on Safari, so they run off the main thread, with a short
    /// timeout, and are skipped if the user has clicked again or the request has gone stale.
    func focusSafari(then completion: (() -> Void)? = nil) {
        guard let app, !app.isTerminated else { return }
        let ticket = clickActions.newTicket()
        app.activate(from: .current, options: [])
        clickActions.bringForward(window: window, application: appElement, ticket: ticket)

        waitForSafari(attempts: 6) { [weak self] inFront in
            guard let self else { return }
            if inFront {
                completion?()
                return
            }
            // By now the user may have gone elsewhere; don't pull Safari forward over it.
            guard !ticket.isStale, let url = app.bundleURL else { return }
            self.log.notice("Safari didn't come forward; asking LaunchServices")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                DispatchQueue.main.async {
                    self.waitForSafari(attempts: 10) { _ in completion?() }
                }
            }
        }
    }

    /// Presses the button for a tab in the docked window's tab bar. `completion` runs on the main
    /// thread, and says whether that worked or the extension has to switch the tab instead.
    func pressTab(_ target: TabBarTarget, then completion: @escaping (TabBarPressOutcome) -> Void) {
        guard isTrusted, let window else {
            completion(.fallback("there is no docked Safari window"))
            return
        }
        tabBar.press(target, in: window) { outcome in
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Reads which of the docked window's tabs Safari has selected, from its tab bar, given the titles
    /// of the window's tabs as the sidebar has them. `completion` runs on the main thread.
    func selectedTab(windowTitles: [String?], then completion: @escaping (TabBarSelection) -> Void) {
        guard isTrusted, let window else {
            completion(.unknown("there is no docked Safari window"))
            return
        }
        tabBar.selectedTab(windowTitles: windowTitles, in: window) { selection in
            DispatchQueue.main.async { completion(selection) }
        }
    }

    /// When Safari is in front but another of its windows has focus (Settings, a second
    /// window), makes the window the sidebar is docked to the focused one.
    ///
    /// Safari's notifications keep `focusedWindow` current, so the usual click, with the
    /// docked window already focused, makes no Accessibility call at all. Otherwise the
    /// raise is sent off the main thread.
    func raiseDockedWindowIfNeeded() {
        guard let window else { return }
        if let focusedWindow, CFEqual(focusedWindow, window) {
            return
        }
        clickActions.bringForward(window: window, application: nil, ticket: clickActions.newTicket())
    }

    /// Polls every 25 ms until Safari is the frontmost app or the attempts run out.
    private func waitForSafari(attempts: Int, _ done: @escaping (Bool) -> Void) {
        if isSafariFrontmost || attempts <= 0 {
            done(isSafariFrontmost)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.waitForSafari(attempts: attempts - 1, done)
        }
    }
}

extension CGRect {
    /// Converts between AX/CoreGraphics coordinates (top-left origin) and AppKit screen
    /// coordinates (bottom-left origin). The conversion is its own inverse.
    var flippedScreenCoordinates: CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: mainHeight - maxY, width: width, height: height)
    }
}
