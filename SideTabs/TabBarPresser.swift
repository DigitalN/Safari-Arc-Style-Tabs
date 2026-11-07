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
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "tracker")

    // Only used on `queue`.
    private var cachedTabBar: (window: AXUIElement, bar: AXUIElement)?
    // [TEMP-tabSwitchMethod] The fallback diagnostics (this, the `diagnostic` closures `attempt`
    // returns, `describe` and `describeChildren`) write the window's tab titles to the system log,
    // public. They are for measuring the tab bar press and go with the switch, not before.
    private var lastDiagnostic = ""

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
            let (outcome, diagnostic) = attempt(target, in: window, issued: issued, isStale: isStale)
            completion(outcome)
            // After the answer is on its way: the explanation costs more Accessibility calls.
            // [TEMP-tabSwitchMethod] Logs tab titles, public.
            if let diagnostic, case .fallback = outcome {
                let text = diagnostic()
                if text != lastDiagnostic {
                    lastDiagnostic = text
                    log.notice("tab bar: \(text, privacy: .public)")
                }
            }
        }
    }

    private func attempt(
        _ target: TabBarTarget,
        in window: AXUIElement,
        issued: Date,
        isStale: () -> Bool
    ) -> (TabBarPressOutcome, diagnostic: (() -> String)?) {
        query.clearTimedOut()
        /// A reason to stop now, if there is one.
        func stop() -> TabBarPressOutcome? {
            if isStale() { return .superseded }
            if query.timedOut { return .fallback("Safari didn't answer in time") }
            if Date().timeIntervalSince(issued) > Self.budget { return .fallback("took longer than \(Int(Self.budget * 1000)) ms") }
            return nil
        }

        if let outcome = stop() { return (outcome, nil) }
        guard let bar = tabBar(in: window) else {
            if let outcome = stop() { return (outcome, nil) }
            return (.fallback("the window has no tab bar"), { [self] in describeChildren(of: window) })
        }
        if let outcome = stop() { return (outcome, nil) }
        let buttons = TabBarFinder.buttons(in: bar)
        if let outcome = stop() { return (outcome, nil) }

        switch TabBarFinder.choose(target, among: buttons) {
        case .fallback(let reason):
            return (.fallback(reason), { Self.describe(buttons, for: target) })
        case .press(let button):
            let error = query.perform(button.element, kAXPressAction)
            guard error == .success else {
                let reason = query.timedOut ? "Safari didn't answer the press in time" : "the press failed (error \(error.rawValue))"
                return (.fallback(reason), { Self.describe(buttons, for: target) })
            }
            return (.pressed(milliseconds: Int(Date().timeIntervalSince(issued) * 1000)), nil)
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

    // MARK: - Explaining a fallback

    /// What the tab bar looked like, for the log, so a fallback that shouldn't have happened can
    /// be understood without Safari in front of you.
    ///
    /// [TEMP-tabSwitchMethod] Puts up to eight of the window's tab titles in the log. Browsing
    /// titles shouldn't stay in the system log once the measurements are done: delete this and
    /// `describeChildren` with the rest of the marked code.
    private static func describe(_ buttons: [TabBarButton<AXTabBarNode>], for target: TabBarTarget) -> String {
        func quoted(_ title: String?) -> String {
            let text = TabBarMatcher.normalized(title)
            return "“" + (text.count > 28 ? String(text.prefix(28)) + "…" : text) + "”"
        }
        let order = TabBarMatcher.visualOrder(of: buttons.map(\.item))
        let shown = order.prefix(8).map { quoted(buttons[$0].item.title) }.joined(separator: ", ")
        let tabs = target.windowTitles.prefix(8).map(quoted).joined(separator: ", ")
        return "\(buttons.count) buttons [\(shown)\(order.count > 8 ? ", …" : "")] for \(target.windowTitles.count) tabs [\(tabs)\(target.windowTitles.count > 8 ? ", …" : "")]; wanted \(quoted(target.title)) at \(target.position)"
    }

    // [TEMP-tabSwitchMethod] Part of the same diagnostics (it names no titles, but is only used by them).
    /// What the search looked through, so a layout it doesn't know can be told from a window that
    /// really has no tab bar: each element as `role/subrole#identifier`, with `>` marks for its depth.
    private func describeChildren(of window: AXUIElement) -> String {
        var lines: [String] = []
        func visit(_ element: AXUIElement, depth: Int) {
            guard lines.count < 40, depth <= TabBarFinder.searchDepth else { return }
            for child in query.elements(element, kAXChildrenAttribute) {
                guard let node = AXTabBarNode(child, query: query) else { continue }
                let subrole = node.subrole.map { "/" + $0 } ?? ""
                // Up to the first "=": identifiers carry values such as the profile's name.
                let identifier = node.identifier.map { "#" + String($0.prefix(while: { $0 != "=" }).prefix(32)) } ?? ""
                lines.append(String(repeating: ">", count: depth) + (node.role ?? "?") + subrole + identifier)
                if let role = node.role, ["AXToolbar", "AXGroup", "AXSplitGroup"].contains(role) {
                    visit(child, depth: depth + 1)
                }
            }
        }
        visit(window, depth: 1)
        return "no tab bar found: \(lines.joined(separator: " "))"
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
