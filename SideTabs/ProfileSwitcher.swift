import AppKit
@preconcurrency import ApplicationServices
import os

/// Switches Safari to another profile in place, opens Settings at Profiles, and takes the user to a
/// profile's extensions, all through Accessibility and off the main thread (#33, measured in #28).
///
/// A switch brings the profile's most recently used window forward in exactly the docked window's
/// spot: while it's still behind, it gets the docked window's frame, then it's raised and made main,
/// and Safari is activated (8–115 ms in #28). The old window stays open behind it, and the sidebar
/// follows on its own. A profile with no window gets one from File → New Window, which works for
/// every profile, including ones where Side Tabs is off; the new window gets the frame as soon as it
/// appears (about 0.5–0.8 s).
///
/// Runs on ProfileReader's queue, so it uses what the reader keeps (each window's profile, the menu).
nonisolated final class ProfileSwitcher: @unchecked Sendable {
    enum Outcome: Sendable {
        /// The profile's window was brought forward and was Safari's main window this many ms after
        /// the click.
        case raised(milliseconds: Int, minimized: Bool)
        /// A new window was opened for the profile; it appeared this many ms after the click.
        case opened(milliseconds: Int)
        /// File → New Window has no item for the profile: the list is out of date.
        case menuOutOfDate
        /// A newer switch was asked for before this one was done.
        case superseded
        case failed(String)
    }

    /// What a switch needs, gathered on the main thread at the click.
    struct Request: @unchecked Sendable {
        let application: AXUIElement
        let processIdentifier: pid_t
        let profile: SafariProfile
        /// Its position in File → New Window.
        let position: Int
        /// The docked window's frame (AX coordinates), which the window brought forward gets. Nil when
        /// it isn't known, or the docked window is full screen.
        let frame: CGRect?
        /// Which profile a window belongs to, from its toolbar and title (ProfileRules.resolve, with
        /// what the app knew at the click).
        let resolve: @Sendable (ToolbarProfile, String?) -> ProfileResolution
    }

    private let reader: ProfileReader
    private var query: AXQuery { reader.query }
    private let latest = OSAllocatedUnfairLock(initialState: 0)
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "profiles")

    /// How long to wait for a window opened from the menu to appear.
    private static let newWindowWait: TimeInterval = 3
    /// How long to wait for a raised window to become Safari's main window before raising it again.
    private static let mainWindowWait: TimeInterval = 0.4

    init(reader: ProfileReader) {
        self.reader = reader
    }

    // MARK: - Switching

    /// Switches to `request.profile`. `completion` runs on a background queue.
    func switchTo(_ request: Request, clickAt: Date, then completion: @escaping @Sendable (Outcome) -> Void) {
        let generation = latest.withLock { value -> Int in
            value += 1
            return value
        }
        reader.queue.async { [self] in
            let isStale = { [latest] in latest.withLock { $0 } != generation }
            guard !isStale() else {
                completion(.superseded)
                return
            }
            let windows = reader.windows(application: request.application)
            let facts = windows.map {
                WindowFacts(number: $0.number, profile: request.resolve($0.toolbar, $0.title), isMinimized: $0.isMinimized)
            }
            if let target = ProfileRules.switchTarget(for: request.profile.id, among: facts),
               let window = windows.first(where: { $0.number == target.number }) {
                completion(bringForward(window, request: request, clickAt: clickAt, isStale: isStale))
            } else {
                completion(openWindow(request, clickAt: clickAt, isStale: isStale))
            }
        }
    }

    private func bringForward(_ window: SafariWindowInfo, request: Request, clickAt: Date, isStale: () -> Bool) -> Outcome {
        query.clearTimedOut()
        let frame = window.isFullScreen ? nil : request.frame
        if window.isMinimized {
            // Into place, not where it was before it was minimized: the frame before and after, in
            // case Safari ignores one made while the window is in the Dock.
            if let frame { setFrame(frame, of: window.element) }
            query.set(window.element, kAXMinimizedAttribute, kCFBooleanFalse)
        }
        if let frame { setFrame(frame, of: window.element) }
        guard !isStale() else { return .superseded }
        raise(window.element, application: request.application)
        activate(request.processIdentifier)
        if !waitUntilMain(window.number, application: request.application, isStale: isStale) {
            guard !isStale() else { return .superseded }
            // Something raised another window after this one (the click itself brings the docked
            // window forward, from another queue): once more.
            raise(window.element, application: request.application)
            guard waitUntilMain(window.number, application: request.application, isStale: isStale) else {
                return isStale() ? .superseded : .failed(query.timedOut ? "Safari didn't answer in time" : "the window didn't become Safari's main window")
            }
        }
        return .raised(milliseconds: milliseconds(since: clickAt), minimized: window.isMinimized)
    }

    private func openWindow(_ request: Request, clickAt: Date, isStale: () -> Bool) -> Outcome {
        var item = ProfileTree.newWindowItem(for: request.profile, at: request.position, among: reader.newWindowItems)
        if item == nil {
            _ = reader.readMenu(application: request.application)
            item = ProfileTree.newWindowItem(for: request.profile, at: request.position, among: reader.newWindowItems)
        }
        guard var item else { return .menuOutOfDate }
        let before = reader.windowNumbers(application: request.application)
        guard !isStale() else { return .superseded }
        query.clearTimedOut()
        if query.perform(item.element, kAXPressAction) != .success {
            // The menu has changed since it was read (Safari keeps its items for a launch, but a
            // profile added or removed rebuilds them): read it again and press once more.
            _ = reader.readMenu(application: request.application)
            guard let again = ProfileTree.newWindowItem(for: request.profile, at: request.position, among: reader.newWindowItems) else {
                return .menuOutOfDate
            }
            item = again
            guard query.perform(item.element, kAXPressAction) == .success else {
                return .failed("pressing File → New Window failed")
            }
        }
        let deadline = Date().addingTimeInterval(Self.newWindowWait)
        while Date() < deadline {
            if isStale() { return .superseded }
            for element in query.elements(request.application, kAXWindowsAttribute) {
                guard let number = reader.number(of: element), !before.contains(number) else { continue }
                let appeared = milliseconds(since: clickAt)
                activate(request.processIdentifier)
                if let frame = request.frame {
                    setFrame(frame, of: element)
                    settle(element, at: frame, isStale: isStale)
                }
                return .opened(milliseconds: appeared)
            }
            usleep(15_000)
        }
        return .failed("no new window within \(Int(Self.newWindowWait)) s")
    }

    // MARK: - Settings

    /// Opens Safari's Settings at Profiles, through Safari → Manage Profiles… `completion` runs on a
    /// background queue with whether the item was pressed.
    func openManageProfiles(application: AXUIElement, processIdentifier: pid_t, then completion: @escaping @Sendable (Bool) -> Void) {
        reader.queue.async { [self] in
            completion(pressManageProfiles(application: application, processIdentifier: processIdentifier))
        }
    }

    /// Takes the user to a profile's extensions, where they turn Side Tabs on: Manage Profiles…,
    /// then the profile's row, then its Extensions tab. Never the checkbox: a scripted tick makes
    /// Safari ask for Touch ID (#28). Not for the default profile, which has no Extensions tab there.
    /// `completion` runs on a background queue with what went wrong, if anything.
    func showExtensions(of profile: SafariProfile, position: Int, profileCount: Int, application: AXUIElement, processIdentifier: pid_t, then completion: @escaping @Sendable (String?) -> Void) {
        reader.queue.async { [self] in
            guard pressManageProfiles(application: application, processIdentifier: processIdentifier) else {
                completion("Manage Profiles… not found")
                return
            }
            // Settings appears about 440 ms after the press (#28).
            var pane: AXProfileNode?
            let deadline = Date().addingTimeInterval(3)
            while pane == nil, Date() < deadline {
                query.clearTimedOut()
                for element in query.elements(application, kAXWindowsAttribute) {
                    if let found = ProfileTree.profilesPane(in: AXProfileNode(element, query: query)) {
                        pane = found
                        break
                    }
                }
                if pane == nil { usleep(20_000) }
            }
            guard let pane else {
                completion("Settings didn't show Profiles within 3 s")
                return
            }
            guard let table = ProfileTree.profilesTable(in: pane) else {
                completion("no list of profiles in Settings")
                return
            }
            let rows = query.elements(table.element, kAXRowsAttribute)
            guard let row = Self.row(for: profile, position: position, profileCount: profileCount, rows: rows, name: rowName) else {
                completion("no row for the profile among \(rows.count)")
                return
            }
            if query.set(row, kAXSelectedAttribute, kCFBooleanTrue) != .success {
                query.set(table.element, kAXSelectedRowsAttribute, [row] as CFArray)
            }
            // The tabs belong to the selected profile, so look for them once the row is selected.
            var tabs: [AXProfileNode] = []
            let tabsDeadline = Date().addingTimeInterval(1)
            repeat {
                usleep(30_000)
                tabs = ProfileTree.profileTabs(in: pane)
            } while tabs.count <= ProfileTree.extensionsTabIndex && Date() < tabsDeadline
            guard tabs.count > ProfileTree.extensionsTabIndex else {
                completion("the profile has no Extensions tab")
                return
            }
            let error = query.perform(tabs[ProfileTree.extensionsTabIndex].element, kAXPressAction)
            completion(error == .success ? nil : "pressing the Extensions tab failed (\(error.rawValue))")
        }
    }

    /// The row for `profile` in Settings → Profiles, which lists profiles in Safari's order. By
    /// position when the list is as long as the menu; otherwise the one row with the profile's name.
    private static func row(for profile: SafariProfile, position: Int, profileCount: Int, rows: [AXUIElement], name: (AXUIElement) -> String?) -> AXUIElement? {
        if rows.count == profileCount, rows.indices.contains(position) {
            return rows[position]
        }
        let named = rows.filter { name($0).map { ProfileIdentifiers.sameName($0, profile.name) } ?? false }
        return named.count == 1 ? named[0] : nil
    }

    /// The name in a row of Settings → Profiles: its text field's value. Never logged.
    private func rowName(_ row: AXUIElement) -> String? {
        for cell in query.elements(row, kAXChildrenAttribute) {
            for child in query.elements(cell, kAXChildrenAttribute) where query.string(child, kAXRoleAttribute) == kAXTextFieldRole {
                return query.string(child, kAXValueAttribute)
            }
        }
        return nil
    }

    private func pressManageProfiles(application: AXUIElement, processIdentifier: pid_t) -> Bool {
        query.clearTimedOut()
        guard let item = reader.manageProfiles(application: application) else { return false }
        guard query.perform(item, kAXPressAction) == .success else { return false }
        activate(processIdentifier)
        return true
    }

    // MARK: - Steps

    /// Position, size, position: shrinking can be blocked until the window has moved, and a
    /// constrained resize can nudge the origin (the same as SafariWindowReader.setFrame).
    private func setFrame(_ frame: CGRect, of window: AXUIElement) {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        query.set(window, kAXPositionAttribute, positionValue)
        query.set(window, kAXSizeAttribute, sizeValue)
        query.set(window, kAXPositionAttribute, positionValue)
    }

    /// A new window opens at Safari's default frame, and the sidebar docks to it and may move it out
    /// of its way (DockController.makeRoom) from what it read before the frame above was set. Looks
    /// twice more, a quarter of a second apart, and puts it back if it was moved.
    private func settle(_ window: AXUIElement, at frame: CGRect, isStale: () -> Bool) {
        for _ in 0..<2 {
            usleep(250_000)
            guard !isStale(), let current = currentFrame(of: window) else { return }
            if abs(current.minX - frame.minX) > 1 || abs(current.minY - frame.minY) > 1
                || abs(current.width - frame.width) > 1 || abs(current.height - frame.height) > 1 {
                setFrame(frame, of: window)
            }
        }
    }

    private func currentFrame(of window: AXUIElement) -> CGRect? {
        guard let positionValue = query.value(window, kAXPositionAttribute),
              let sizeValue = query.value(window, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func raise(_ window: AXUIElement, application: AXUIElement) {
        query.perform(window, kAXRaiseAction)
        query.set(window, kAXMainAttribute, kCFBooleanTrue)
        query.set(application, kAXFrontmostAttribute, kCFBooleanTrue)
    }

    /// Safari is usually in front already: the click brought it forward.
    private func activate(_ processIdentifier: pid_t) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                _ = NSRunningApplication(processIdentifier: processIdentifier)?.activate(from: .current, options: [])
            }
        }
    }

    private func waitUntilMain(_ number: Int, application: AXUIElement, isStale: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(Self.mainWindowWait)
        repeat {
            if let main = query.element(application, kAXMainWindowAttribute), reader.number(of: main) == number {
                return true
            }
            if isStale() { return false }
            usleep(8_000)
        } while Date() < deadline
        return false
    }

    private func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
