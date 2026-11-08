import CoreGraphics
import Foundation

// Finding Safari's tab bar in a window's Accessibility tree, and the button in it for a tab.
// Kept apart from the Accessibility calls (TabBarPresser) so it can be checked against recorded
// trees of Safari's windows (Tests/TabBarFinderChecks/trees) without Safari.

/// One element of Safari's Accessibility tree, as far as the search needs to know it. The real
/// ones read their attributes from Safari (TabBarPresser.swift); the checks use recorded ones.
nonisolated protocol TabBarNode {
    var role: String? { get }
    var subrole: String? { get }
    /// `AXIdentifier`: not shown to anyone, and not translated.
    var identifier: String? { get }
    var title: String? { get }
    /// `AXDescription`.
    var descriptionText: String? { get }
    /// Left edge on screen.
    var x: CGFloat? { get }
    /// `AXValue`, which Safari 26 sets to 1 on the selected tab's button and 0 on the others.
    var value: Int? { get }
    /// The element's actions. Only asked of the one button about to be pressed.
    var actions: [String] { get }
    /// Reading the children costs a round trip to Safari, so the search reads only where it must.
    func children() -> [Self]
}

/// A tab button in the tab bar, with what the matcher needs to know about it.
nonisolated struct TabBarButton<Node: TabBarNode> {
    let node: Node
    let item: TabBarItem
}

nonisolated enum TabBarChoice<Node: TabBarNode> {
    case press(Node)
    /// The button is the selected tab's: Safari already shows the tab.
    case alreadySelected
    /// Not pressing; use the extension. Says why.
    case fallback(String)
}

nonisolated enum TabBarFinder {
    /// How many levels below the window the search goes. Safari 26 puts the tab bar three levels
    /// down in a window (window → toolbar → group → tab bar) and four in full screen (window →
    /// group → toolbar → group → tab bar).
    static let searchDepth = 4

    static let pressAction = "AXPress"

    /// Elements the search looks inside. The page is under `AXSplitGroup → AXTabGroup`, and
    /// that `AXTabGroup` is not the tab bar (Safari 26 uses it for the area that holds the page),
    /// so it is never entered and never taken. Nor is any other container: web content and
    /// the sidebar are big.
    private static let containerRoles: Set<String> = ["AXToolbar", "AXGroup", "AXSplitGroup"]

    /// How Safari 26 labels its tab bar: `TabBar?isSeparate=false` (or `…=true` for the separate tab
    /// layout), on an `AXOpaqueProviderGroup` whose subrole is `AXOpaqueProviderList`. The tabs'
    /// own buttons are `TabBarTab?…`, which starts the same way and is not this.
    static func isTabBarIdentifier(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier.hasPrefix("TabBar") && !identifier.hasPrefix("TabBarTab")
    }

    static let tabBarSubrole = "AXOpaqueProviderList"

    /// Whether an element with these attributes is the tab bar. The description ("Tab bar, 30
    /// tabs") is translated, so it plays no part.
    static func isTabBar(identifier: String?, subrole: String?) -> Bool {
        isTabBarIdentifier(identifier) || subrole == tabBarSubrole
    }

    // MARK: - Finding the bar

    /// The tab bar in `window`, or nil if it has none (a window with one tab can hide it, and a
    /// layout nobody has seen is treated the same: there is nothing to press). Looks level by
    /// level, so the nearest one wins, and prefers a labelled `TabBar` to another list that
    /// happens to have the same subrole.
    static func tabBar<Node: TabBarNode>(in window: Node) -> Node? {
        var bySubrole: Node?
        var level = [window]
        for _ in 0..<searchDepth {
            var next: [Node] = []
            for container in level {
                for child in container.children() {
                    if isTabBarIdentifier(child.identifier) {
                        return child
                    }
                    if bySubrole == nil, child.subrole == tabBarSubrole {
                        bySubrole = child
                    }
                    if let role = child.role, containerRoles.contains(role) {
                        next.append(child)
                    }
                }
            }
            level = next
            if level.isEmpty { break }
        }
        return bySubrole
    }

    // MARK: - Choosing the button

    /// The tab bar's tab buttons with their titles, where they are, and which is selected. Safari
    /// draws the tabs as radio buttons; the bar's other controls aren't radio buttons.
    static func buttons<Node: TabBarNode>(in bar: Node) -> [TabBarButton<Node>] {
        bar.children().compactMap { node in
            guard node.role == "AXRadioButton" else { return nil }
            // A tab's title, or its description when Safari leaves the title empty.
            let title = node.title.flatMap { $0.isEmpty ? nil : $0 } ?? node.descriptionText
            // Selected is 1 and not selected is 0; any other number isn't understood, so it says nothing.
            let isSelected = node.value.flatMap { $0 == 1 ? true : $0 == 0 ? false : nil }
            return TabBarButton(node: node, item: TabBarItem(title: title, x: node.x, isSelected: isSelected))
        }
    }

    /// The button to press for `target`, or why not. Never guesses (see TabBarMatcher), and never
    /// picks a button that can't be pressed: Safari sometimes shows a tab's button without its
    /// title or actions for a moment after a window opens. A button Safari marks as selected isn't
    /// pressed: the tab is already showing, whatever the sidebar thought.
    static func choose<Node: TabBarNode>(_ target: TabBarTarget, among buttons: [TabBarButton<Node>]) -> TabBarChoice<Node> {
        switch TabBarMatcher.match(target, items: buttons.map(\.item)) {
        case .fallback(let reason):
            return .fallback(reason)
        case .press(let index):
            if buttons[index].item.isSelected == true {
                return .alreadySelected
            }
            let node = buttons[index].node
            guard node.actions.contains(pressAction) else {
                return .fallback("the tab's button has no press action")
            }
            return .press(node)
        }
    }
}
