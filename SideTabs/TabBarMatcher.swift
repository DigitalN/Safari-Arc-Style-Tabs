import Foundation

// Deciding which button in Safari's tab bar is the tab the sidebar wants. Kept apart from the
// Accessibility calls that read the buttons so it can be checked against fixture tab bars.

/// One tab button as Safari's tab bar reports it.
nonisolated struct TabBarItem: Equatable {
    var title: String?
    /// The button's left edge on screen, if Safari said where it is.
    var x: CGFloat?
}

/// The tab the sidebar wants to switch to, with what the sidebar knows about its window.
nonisolated struct TabBarTarget: Equatable {
    var title: String?
    /// The tab's place among its window's tabs, counting from 0 at the left.
    var position: Int
    /// The titles of all of the window's tabs, in order, as the sidebar last heard from Safari.
    var windowTitles: [String?]
}

nonisolated enum TabBarMatch: Equatable {
    /// The button to press, as an index into the items that were given.
    case press(Int)
    /// Not sure enough which button it is; use the extension instead. Says why.
    case fallback(String)
}

nonisolated enum TabBarMatcher {
    /// Finds the button for `target` among `items`, or says to fall back. Never guesses: a button
    /// is chosen only when its title is the tab's and either
    /// - the tab bar has as many buttons as the window has tabs, and the button sits where the
    ///   tab does (and, when another tab has the same title, its neighbours match theirs too); or
    /// - no other tab in the window and no other button has that title.
    static func match(_ target: TabBarTarget, items: [TabBarItem]) -> TabBarMatch {
        let wanted = normalized(target.title)
        guard !wanted.isEmpty else {
            return .fallback("the tab has no title to recognise it by")
        }
        guard !items.isEmpty else {
            return .fallback("no tab buttons (the tab bar is hidden)")
        }
        let order = visualOrder(of: items)
        let tabTitles = target.windowTitles.map(normalized)
        let sameTitleTabs = tabTitles.filter { $0 == wanted }.count

        // By position: the buttons line up with the tabs, one for one.
        if order.count == tabTitles.count, tabTitles.indices.contains(target.position),
           tabTitles[target.position] == wanted {
            let item = order[target.position]
            if normalized(items[item].title) == wanted {
                if sameTitleTabs == 1 {
                    return .press(item)
                }
                // Another tab has this title, so the position is all that tells them apart, and
                // the sidebar's idea of the order may be a moment behind Safari's. The
                // neighbours have to agree as well.
                let neighbours = [target.position - 1, target.position + 1].filter(tabTitles.indices.contains)
                let agree = neighbours.allSatisfy { index in
                    !tabTitles[index].isEmpty && normalized(items[order[index]].title) == tabTitles[index]
                }
                return agree ? .press(item) : .fallback("another tab has the same title and the buttons next to it don't line up")
            }
        }

        // By title alone: only when nothing else has it.
        let buttons = order.filter { normalized(items[$0].title) == wanted }
        if sameTitleTabs == 1 && buttons.count == 1 {
            return .press(buttons[0])
        }
        if buttons.isEmpty {
            return .fallback("no button has the tab's title (\(items.count) buttons for \(tabTitles.count) tabs)")
        }
        if order.count != tabTitles.count {
            return .fallback("\(items.count) buttons for \(tabTitles.count) tabs, and the title isn't unique")
        }
        return .fallback("the buttons don't line up with the tabs, and the title isn't unique")
    }

    /// Indices of `items` from left to right. Without positions for all of them, as given.
    static func visualOrder(of items: [TabBarItem]) -> [Int] {
        let indices = Array(items.indices)
        guard items.allSatisfy({ $0.x != nil }) else { return indices }
        return indices.sorted { lhs, rhs in
            let (left, right) = (items[lhs].x ?? 0, items[rhs].x ?? 0)
            return left == right ? lhs < rhs : left < right
        }
    }

    /// A title as comparisons see it: without leading, trailing or repeated whitespace, and with
    /// accented letters in one form, so Safari's and the extension's spelling of one title agree.
    static func normalized(_ title: String?) -> String {
        guard let title else { return "" }
        let words = title.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace)
        return words.joined(separator: " ")
    }
}

/// How an attempt to switch tabs by pressing the tab's button in Safari's tab bar turned out.
nonisolated enum TabBarPressOutcome: Equatable {
    /// The button was pressed. Safari reports the switch the usual way.
    case pressed(milliseconds: Int)
    /// Nothing was pressed; use the extension. Says why.
    case fallback(String)
    /// A later click replaced this one before it ran, so there is nothing left to do for it.
    case superseded
}
