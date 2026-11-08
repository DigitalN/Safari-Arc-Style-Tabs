import AppKit
@preconcurrency import ApplicationServices
import os

/// The Accessibility requests a click on the sidebar makes of Safari: raise its window, make it
/// frontmost, press its Open Location menu item.
///
/// They run on one queue, off the main thread, because each waits for Safari's main thread. Safari
/// can be busy for seconds, and a request still queued by then must not run: it would raise a
/// window or pull Safari forward long after the click, over whatever the user has moved on to.
/// So every request carries a ticket, and the queue skips the ones that are no longer current.
nonisolated final class ClickActions: @unchecked Sendable {
    /// Proof that a request belongs to the latest click and isn't too old to still be wanted.
    struct Ticket: Sendable {
        /// Requests older than this are dropped without being sent.
        static let lifetime: TimeInterval = 1

        fileprivate let generation: Int
        fileprivate let issued: Date
        fileprivate let latest: OSAllocatedUnfairLock<Int>

        var isStale: Bool {
            latest.withLock { $0 } != generation || Date().timeIntervalSince(issued) > Self.lifetime
        }
    }

    private let queue = DispatchQueue(label: "com.digitaln.sidetabs.accessibility-click", qos: .userInteractive)
    /// A click won't wait longer than this for any one request.
    private let query = AXQuery(timeout: 0.25)
    private let latest = OSAllocatedUnfairLock(initialState: 0)
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "tracker")
    /// Safari's File → Open Location… menu item, found once per Safari launch. Only used on `queue`.
    private var openLocationItem: AXUIElement?

    /// A ticket for a new click. Every ticket issued before it goes stale.
    func newTicket() -> Ticket {
        let generation = latest.withLock { value -> Int in
            value += 1
            return value
        }
        return Ticket(generation: generation, issued: Date(), latest: latest)
    }

    /// A ticket for more work belonging to the click that's already under way, which doesn't
    /// cancel what that click queued earlier.
    func currentTicket() -> Ticket {
        Ticket(generation: latest.withLock { $0 }, issued: Date(), latest: latest)
    }

    /// Makes `window` Safari's main window and raises it, and, given the application, asks for
    /// it to be frontmost.
    func bringForward(window: AXUIElement?, application: AXUIElement?, ticket: Ticket) {
        queue.async { [query] in
            guard !ticket.isStale else { return }
            if let window {
                query.set(window, kAXMainAttribute, kCFBooleanTrue)
                guard !ticket.isStale else { return }
                query.perform(window, kAXRaiseAction)
            }
            guard !ticket.isStale, let application else { return }
            query.set(application, kAXFrontmostAttribute, kCFBooleanTrue)
        }
    }

    /// Puts the cursor in Safari's own address bar, like pressing ⌘L. Presses the menu item
    /// whose shortcut is ⌘L (so it works in any language and keyboard layout), or sends the
    /// keystroke if that item can't be found.
    func pressOpenLocation(application: AXUIElement, processIdentifier: pid_t, ticket: Ticket) {
        queue.async { [self] in
            guard !ticket.isStale else { return }
            if openLocationItem == nil {
                openLocationItem = findMenuItem(application, commandKey: "L", ticket: ticket)
            }
            guard !ticket.isStale else { return }
            if let item = openLocationItem, query.perform(item, kAXPressAction) == .success {
                return
            }
            openLocationItem = nil
            log.notice("Open Location menu item not found; sending ⌘L instead")
            let source = CGEventSource(stateID: .hidSystemState)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0x25, keyDown: keyDown) // L
                event?.flags = .maskCommand
                event?.postToPid(processIdentifier)
            }
        }
    }

    /// Forgets the menu item when Safari quits: it belongs to that launch.
    func forgetMenuItem() {
        queue.async { [self] in openLocationItem = nil }
    }

    /// A menu item whose shortcut is ⌘ plus `commandKey`. Starts with the File menu, where Open
    /// Location lives, to keep the search short.
    private func findMenuItem(_ application: AXUIElement, commandKey: String, ticket: Ticket) -> AXUIElement? {
        guard let menuBar = query.element(application, kAXMenuBarAttribute) else { return nil }
        var menus = query.elements(menuBar, kAXChildrenAttribute)
        if menus.count > 2 {
            menus.insert(menus.remove(at: 2), at: 0)
        }
        for menuBarItem in menus {
            for menu in query.elements(menuBarItem, kAXChildrenAttribute) {
                for item in query.elements(menu, kAXChildrenAttribute) {
                    guard !ticket.isStale else { return nil }
                    guard query.string(item, kAXMenuItemCmdCharAttribute) == commandKey,
                          (query.copy(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0 else { continue }
                    return item
                }
            }
        }
        return nil
    }
}
