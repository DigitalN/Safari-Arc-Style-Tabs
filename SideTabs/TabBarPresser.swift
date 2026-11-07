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
    private var cachedTabGroup: (window: AXUIElement, group: AXUIElement)?
    private var lastDiagnostic = ""

    private struct Button {
        let element: AXUIElement
        let item: TabBarItem
    }

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
        guard let group = tabGroup(in: window) else {
            if let outcome = stop() { return (outcome, nil) }
            return (.fallback("the window has no tab bar"), { [self] in describeChildren(of: window) })
        }
        if let outcome = stop() { return (outcome, nil) }
        let buttons = buttons(in: group)
        if let outcome = stop() { return (outcome, nil) }

        switch TabBarMatcher.match(target, items: buttons.map(\.item)) {
        case .fallback(let reason):
            return (.fallback(reason), { Self.describe(buttons, for: target) })
        case .press(let index):
            let error = query.perform(buttons[index].element, kAXPressAction)
            guard error == .success else {
                let reason = query.timedOut ? "Safari didn't answer the press in time" : "the press failed (error \(error.rawValue))"
                return (.fallback(reason), { Self.describe(buttons, for: target) })
            }
            return (.pressed(milliseconds: Int(Date().timeIntervalSince(issued) * 1000)), nil)
        }
    }

    // MARK: - Finding the buttons

    /// The window's tab bar. It stays the same element while it exists, so the last one found is
    /// tried first.
    private func tabGroup(in window: AXUIElement) -> AXUIElement? {
        if let cached = cachedTabGroup {
            if CFEqual(cached.window, window), query.string(cached.group, kAXRoleAttribute) == kAXTabGroupRole {
                return cached.group
            }
            cachedTabGroup = nil
        }
        guard let group = findTabGroup(in: window, depth: 3) else { return nil }
        cachedTabGroup = (window, group)
        return group
    }

    /// Looks among the window's children, and inside its toolbars and groups (Safari's compact tab
    /// layout puts the tabs in the toolbar), but never into the page.
    private func findTabGroup(in container: AXUIElement, depth: Int) -> AXUIElement? {
        var inner: [AXUIElement] = []
        for child in query.elements(container, kAXChildrenAttribute) {
            guard let role = query.string(child, kAXRoleAttribute) else { continue }
            if role == kAXTabGroupRole {
                return child
            }
            if role == kAXToolbarRole || role == kAXGroupRole {
                inner.append(child)
            }
            if query.timedOut { return nil }
        }
        guard depth > 1 else { return nil }
        for child in inner {
            if let found = findTabGroup(in: child, depth: depth - 1) {
                return found
            }
        }
        return nil
    }

    /// The tab buttons of a tab bar, with their titles and where they are. Safari draws the tabs
    /// as radio buttons; the bar's "+" is a plain button and isn't one of them.
    private func buttons(in group: AXUIElement) -> [Button] {
        var candidates = query.elements(group, kAXChildrenAttribute)
        var buttons = read(candidates)
        if buttons.isEmpty {
            candidates = query.elements(group, kAXTabsAttribute)
            buttons = read(candidates)
        }
        return buttons
    }

    private func read(_ elements: [AXUIElement]) -> [Button] {
        let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPositionAttribute]
        var buttons: [Button] = []
        for element in elements {
            guard let values = query.copyMultiple(element, attributes), values.count == attributes.count else {
                if query.timedOut { return [] }
                continue
            }
            guard values[0] as? String == kAXRadioButtonRole else { continue }
            let title = (values[1] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? values[2] as? String
            var x: CGFloat?
            if let value = values[3], CFGetTypeID(value) == AXValueGetTypeID() {
                var point = CGPoint.zero
                if AXValueGetValue(value as! AXValue, .cgPoint, &point) {
                    x = point.x
                }
            }
            buttons.append(Button(element: element, item: TabBarItem(title: title, x: x)))
        }
        return buttons
    }

    // MARK: - Explaining a fallback

    /// What the tab bar looked like, for the log, so a fallback that shouldn't have happened can
    /// be understood without Safari in front of you.
    private static func describe(_ buttons: [Button], for target: TabBarTarget) -> String {
        func quoted(_ title: String?) -> String {
            let text = TabBarMatcher.normalized(title)
            return "“" + (text.count > 28 ? String(text.prefix(28)) + "…" : text) + "”"
        }
        let order = TabBarMatcher.visualOrder(of: buttons.map(\.item))
        let shown = order.prefix(8).map { quoted(buttons[$0].item.title) }.joined(separator: ", ")
        let tabs = target.windowTitles.prefix(8).map(quoted).joined(separator: ", ")
        return "\(buttons.count) buttons [\(shown)\(order.count > 8 ? ", …" : "")] for \(target.windowTitles.count) tabs [\(tabs)\(target.windowTitles.count > 8 ? ", …" : "")]; wanted \(quoted(target.title)) at \(target.position)"
    }

    private func describeChildren(of window: AXUIElement) -> String {
        let roles = query.elements(window, kAXChildrenAttribute).map { query.string($0, kAXRoleAttribute) ?? "?" }
        return "no tab bar among the window's children: \(roles.joined(separator: ", "))"
    }
}
