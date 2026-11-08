import AppKit
@preconcurrency import ApplicationServices
import os

/// Switches a tab by pressing its button in Safari's tab bar through Accessibility, which takes a
/// few milliseconds, where asking the extension to do it takes about a hundred (Safari hands the
/// app's command to the extension's page slowly).
///
/// Everything happens off the main thread, with short timeouts, and never presses a button unless
/// it's sure which tab it belongs to (see TabBarMatcher). Whenever it isn't, or the press fails,
/// or Safari is too slow, the outcome says to fall back to the extension.
nonisolated final class TabBarPresser: @unchecked Sendable {
    /// From the click to the press, all of it has to fit in this, or the extension is used
    /// instead: a busy Safari answers the extension no faster, but it shouldn't be asked twice
    /// as long to find out.
    static let budget: TimeInterval = 0.3

    private let queue = DispatchQueue(label: "com.digitaln.sidetabs.accessibility-tabbar", qos: .userInteractive)
    private let query = AXQuery(timeout: 0.15)
    private let latest = OSAllocatedUnfairLock(initialState: 0)

    // Only used on `queue`.
    private var cachedTabBar: (window: AXUIElement, bar: AXUIElement)?

    /// Tries to press the button for `target` in `window`'s tab bar. `completion` runs on a
    /// background queue.
    func press(_ target: TabBarTarget, in window: AXUIElement, then completion: @escaping @Sendable (TabBarPressOutcome) -> Void) {
        let issued = Date()
        let generation = latest.withLock { value -> Int in
            value += 1
            return value
        }
        queue.async { [self] in
            let isStale = { [latest] in latest.withLock { $0 } != generation }
            completion(attempt(target, in: window, issued: issued, isStale: isStale))
        }
    }

    private func attempt(
        _ target: TabBarTarget,
        in window: AXUIElement,
        issued: Date,
        isStale: () -> Bool
    ) -> TabBarPressOutcome {
        query.clearTimedOut()
        /// A reason to stop now, if there is one.
        func stop() -> TabBarPressOutcome? {
            if isStale() { return .superseded }
            if query.timedOut { return .fallback("Safari didn't answer in time") }
            if Date().timeIntervalSince(issued) > Self.budget { return .fallback("took longer than \(Int(Self.budget * 1000)) ms") }
            return nil
        }

        if let outcome = stop() { return outcome }
        guard let bar = tabBar(in: window) else {
            return stop() ?? .fallback("the window has no tab bar")
        }
        if let outcome = stop() { return outcome }
        let buttons = TabBarFinder.buttons(in: bar)
        if let outcome = stop() { return outcome }

        switch TabBarFinder.choose(target, among: buttons) {
        case .fallback(let reason):
            return .fallback(reason)
        case .press(let button):
            let error = query.perform(button.element, kAXPressAction)
            guard error == .success else {
                return .fallback(query.timedOut ? "Safari didn't answer the press in time" : "the press failed (error \(error.rawValue))")
            }
            return .pressed(milliseconds: Int(Date().timeIntervalSince(issued) * 1000))
        }
    }

    // MARK: - Finding the tab bar

    /// The window's tab bar. It stays the same element while it exists, so the last one found is
    /// tried first.
    private func tabBar(in window: AXUIElement) -> AXTabBarNode? {
        if let cached = cachedTabBar {
            if CFEqual(cached.window, window), let node = AXTabBarNode(cached.bar, query: query),
               TabBarFinder.isTabBar(identifier: node.identifier, subrole: node.subrole) {
                return node
            }
            cachedTabBar = nil
        }
        guard let root = AXTabBarNode(window, query: query), let bar = TabBarFinder.tabBar(in: root) else { return nil }
        cachedTabBar = (window, bar.element)
        return bar
    }
}

/// An element of Safari's Accessibility tree, read through `AXQuery`. Every element is read with
/// one round trip to Safari.
nonisolated struct AXTabBarNode: TabBarNode {
    let element: AXUIElement
    private let query: AXQuery
    let role: String?
    let subrole: String?
    let identifier: String?
    let title: String?
    let descriptionText: String?
    let x: CGFloat?

    /// nil if Safari doesn't answer for the element (it went away, or it's too slow).
    init?(_ element: AXUIElement, query: AXQuery) {
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPositionAttribute]
        guard let values = query.copyMultiple(element, attributes), values.count == attributes.count else { return nil }
        self.element = element
        self.query = query
        role = values[0] as? String
        subrole = values[1] as? String
        identifier = values[2] as? String
        title = values[3] as? String
        descriptionText = values[4] as? String
        var x: CGFloat?
        if let value = values[5], CFGetTypeID(value) == AXValueGetTypeID() {
            var point = CGPoint.zero
            if AXValueGetValue(value as! AXValue, .cgPoint, &point) {
                x = point.x
            }
        }
        self.x = x
    }

    var actions: [String] { query.actionNames(element) }

    func children() -> [AXTabBarNode] {
        query.elements(element, kAXChildrenAttribute).compactMap { AXTabBarNode($0, query: query) }
    }
}
