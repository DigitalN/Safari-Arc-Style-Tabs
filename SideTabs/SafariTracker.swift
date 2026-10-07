import AppKit
import ApplicationServices
import os.log

/// Private but long-stable API (used by most window managers) that maps an AX window to
/// its window server id, so the panel can be ordered directly above Safari's window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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
final class SafariTracker {
    static let safariBundleID = "com.apple.Safari"

    enum Event {
        case focusChanged
        case moved
        case resized
        case visibilityChanged
        case launched
        case terminated
    }

    var onEvent: ((Event) -> Void)?

    private(set) var app: NSRunningApplication?
    /// The browser window the sidebar docks to.
    private(set) var window: AXUIElement?

    private var appElement: AXUIElement?
    private var observer: AXObserver?
    /// Safari's File → Open Location… menu item, found once per Safari launch.
    private var openLocationItem: AXUIElement?
    private var workspaceTokens: [NSObjectProtocol] = []
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "tracker")
    private var lastWindowDescription = ""

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

    private static let windowNotifications = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
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
                tracker.onEvent?(.launched)
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
                tracker.refreshWindow()
            }
            tracker.onEvent?(.focusChanged)
        }
        observe(NSWorkspace.didHideApplicationNotification) { tracker, _ in tracker.onEvent?(.visibilityChanged) }
        observe(NSWorkspace.didUnhideApplicationNotification) { tracker, _ in tracker.onEvent?(.visibilityChanged) }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { tracker, _ in
            tracker.refreshWindow()
            tracker.onEvent?(.visibilityChanged)
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
        } else if window == nil {
            refreshWindow()
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

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var failures: [String] = []
        for name in Self.appNotifications {
            let error = AXObserverAddNotification(created, element, name as CFString, refcon)
            if error != .success {
                failures.append("\(name)=\(error.rawValue)")
            }
        }
        log.notice("attached to Safari pid \(app.processIdentifier); notification failures: \(failures.isEmpty ? "none" : failures.joined(separator: ", "), privacy: .public)")
        guard failures.count < Self.appNotifications.count else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        appElement = element
        observer = created
        refreshWindow()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        appElement = nil
        window = nil
        openLocationItem = nil
    }

    private func handle(_ name: String, element: AXUIElement) {
        switch name {
        case kAXWindowMovedNotification:
            if let window, CFEqual(window, element) {
                onEvent?(.moved)
            }
        case kAXWindowResizedNotification:
            if let window, CFEqual(window, element) {
                onEvent?(.resized)
            }
        case kAXApplicationHiddenNotification, kAXApplicationShownNotification:
            onEvent?(.visibilityChanged)
        case kAXWindowMiniaturizedNotification, kAXUIElementDestroyedNotification:
            refreshWindow()
            onEvent?(.visibilityChanged)
        default:
            refreshWindow()
            onEvent?(.focusChanged)
        }
    }

    // MARK: - Choosing the window

    /// Picks the browser window to dock to: the focused one if it's a browser window,
    /// otherwise keeps the current one, otherwise the frontmost browser window.
    func refreshWindow() {
        guard let appElement else {
            setWindow(nil)
            return
        }
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let candidate = element(appElement, attribute), isBrowserWindow(candidate) {
                setWindow(candidate)
                return
            }
        }
        if let window, isBrowserWindow(window) {
            return
        }
        let windows = elements(appElement, kAXWindowsAttribute)
        setWindow(windows.first(where: isBrowserWindow))
        if window == nil {
            let description = windows.isEmpty ? "Safari reports no windows" : windows.map(describe).joined(separator: "; ")
            if description != lastWindowDescription {
                lastWindowDescription = description
                log.notice("no browser window among: \(description, privacy: .public)")
            }
        }
    }

    private func describe(_ window: AXUIElement) -> String {
        let button = element(window, kAXFullScreenButtonAttribute)
        let buttonState = button.map { bool($0, kAXEnabledAttribute).map { $0 ? "enabled" : "disabled" } ?? "unknown" } ?? "missing"
        return "“\(title(of: window) ?? "")” role=\(string(window, kAXRoleAttribute) ?? "nil") subrole=\(string(window, kAXSubroleAttribute) ?? "nil") minimized=\(bool(window, kAXMinimizedAttribute).map(String.init) ?? "nil") fullScreenButton=\(buttonState)"
    }

    private func setWindow(_ newWindow: AXUIElement?) {
        if let window, let newWindow, CFEqual(window, newWindow) {
            return
        }
        if let observer, let window {
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(observer, window, name as CFString)
            }
        }
        window = newWindow
        if let observer, let newWindow {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in Self.windowNotifications {
                AXObserverAddNotification(observer, newWindow, name as CFString, refcon)
            }
        }
    }

    /// Browser windows are standard windows that can go full screen. Safari's Settings
    /// window has a disabled full-screen button, which is how it's told apart.
    func isBrowserWindow(_ window: AXUIElement) -> Bool {
        guard string(window, kAXRoleAttribute) == kAXWindowRole,
              string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              bool(window, kAXMinimizedAttribute) != true else { return false }
        if isFullScreen(window) {
            return true
        }
        guard let button = element(window, kAXFullScreenButtonAttribute) else { return false }
        return bool(button, kAXEnabledAttribute) ?? true
    }

    // MARK: - Window geometry (AX coordinates: origin top-left of the main display, y down)

    func frame(of window: AXUIElement) -> CGRect? {
        guard let positionValue = value(window, kAXPositionAttribute),
              let sizeValue = value(window, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        // Position, size, position: shrinking can be blocked until the window has moved,
        // and a constrained resize can nudge the origin.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    }

    func isFullScreen(_ window: AXUIElement) -> Bool {
        bool(window, "AXFullScreen") ?? false
    }

    func title(of window: AXUIElement) -> String? {
        string(window, kAXTitleAttribute)
    }

    /// Bottom edge (AX coordinates) of Safari's toolbar and tab bar, from the window's direct
    /// children only so it stays fast. Nil if Safari doesn't report them (e.g. a hidden
    /// full-screen toolbar).
    func toolbarBottom(of window: AXUIElement) -> CGFloat? {
        guard let windowFrame = frame(of: window) else { return nil }
        var bottom: CGFloat?
        for child in elements(window, kAXChildrenAttribute) {
            guard let role = string(child, kAXRoleAttribute),
                  role == kAXToolbarRole || role == kAXTabGroupRole,
                  let childFrame = frame(of: child),
                  childFrame.height < 200,
                  childFrame.minY < windowFrame.minY + 200 else { continue }
            bottom = max(bottom ?? childFrame.maxY, childFrame.maxY)
        }
        return bottom
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

    func windowNumber(of window: AXUIElement) -> Int? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &id) == .success, id != 0 else { return nil }
        return Int(id)
    }

    /// Puts the cursor in Safari's own address bar, like pressing ⌘L. Presses the menu
    /// item whose shortcut is ⌘L (so it works in any language and keyboard layout), or
    /// sends the keystroke if that item can't be found.
    func openLocation() {
        focusSafari { [weak self] in
            self?.pressOpenLocation()
        }
    }

    private func pressOpenLocation() {
        if openLocationItem == nil {
            openLocationItem = findMenuItem(commandKey: "L")
        }
        if let item = openLocationItem, AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            return
        }
        openLocationItem = nil
        log.notice("Open Location menu item not found; sending ⌘L instead")
        guard let pid = app?.processIdentifier else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x25, keyDown: keyDown) // L
            event?.flags = .maskCommand
            event?.postToPid(pid)
        }
    }

    /// A menu item whose shortcut is ⌘ plus `commandKey`. Starts with the File menu,
    /// where Open Location lives, to keep the search short.
    private func findMenuItem(commandKey: String) -> AXUIElement? {
        guard let appElement, let menuBar = element(appElement, kAXMenuBarAttribute) else { return nil }
        var menus = elements(menuBar, kAXChildrenAttribute)
        if menus.count > 2 {
            menus.insert(menus.remove(at: 2), at: 0)
        }
        for menuBarItem in menus {
            for menu in elements(menuBarItem, kAXChildrenAttribute) {
                for item in elements(menu, kAXChildrenAttribute) {
                    guard string(item, kAXMenuItemCmdCharAttribute) == commandKey,
                          (copy(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0 else { continue }
                    return item
                }
            }
        }
        return nil
    }

    /// Brings Safari and the docked window to the front.
    ///
    /// macOS ignores ordinary activation requests from apps that aren't in front, and Side
    /// Tabs never is (its sidebar doesn't take focus). So ask through Accessibility first,
    /// then the usual way, and if Safari still isn't in front shortly after, have
    /// LaunchServices open it, which brings an already-running app forward.
    func focusSafari(then completion: (() -> Void)? = nil) {
        guard let app, !app.isTerminated else { return }
        if let window {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if isSafariFrontmost {
            completion?()
            return
        }
        if let appElement {
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        app.activate(from: .current, options: [])

        waitForSafari(attempts: 6) { [weak self] inFront in
            guard let self else { return }
            if inFront {
                completion?()
                return
            }
            self.log.notice("Safari didn't come forward; asking LaunchServices")
            guard let url = app.bundleURL else { return }
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

    /// When Safari is in front but another of its windows has focus (Settings, a second
    /// window), makes the window the sidebar is docked to the focused one.
    func raiseDockedWindowIfNeeded() {
        guard let appElement, let window else { return }
        if let focused = element(appElement, kAXFocusedWindowAttribute), CFEqual(focused, window) {
            return
        }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
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

    // MARK: - AX helpers

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (copy(element, attribute) as? [AXUIElement]) ?? []
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copy(element, attribute) as? Bool
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
