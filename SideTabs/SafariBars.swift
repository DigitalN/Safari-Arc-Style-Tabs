import CoreGraphics
import Foundation

// Where the bars Safari shows above the page end: its toolbar, the Favourites bar, the tab bar in the
// separate tab layout, the find bar. The sidebar that slides out over the page (SidebarOverlay.swift)
// starts below the lowest of them. Kept apart from the Accessibility calls (SafariWindowReader) so it
// can be checked against made-up trees (Tests/SidebarOverlayChecks/trees) without Safari.

/// One element of a Safari window's Accessibility tree, as far as finding its bars needs to know it.
/// The real ones read their role, identifier and frame in one round trip (SafariWindowReader); the
/// checks use made-up ones.
nonisolated protocol SafariBarNode {
    var role: String? { get }
    /// `AXIdentifier`: not shown to anyone, and not translated.
    var identifier: String? { get }
    /// In Accessibility coordinates: y down from the top of the main display.
    var frame: CGRect? { get }
    /// Reading the children costs a round trip to Safari, so only the split group's are read.
    func children() -> [Self]
}

/// A bar that counted, for the log.
nonisolated struct SafariBar: Equatable {
    var role: String?
    var identifier: String?
    var frame: CGRect
}

nonisolated enum SafariBars {
    /// Taller than this, it's the page or Safari's own sidebar, not a bar. The full-screen toolbar,
    /// with the Favourites bar, the tab bar and the find bar in it, is still well under.
    static let maximumHeight: CGFloat = 200
    /// How far down the window the first bar may start, as the toolbar could before (#26).
    static let reach: CGFloat = 200
    /// A bar more than this below the one above it isn't between the toolbar and the page, unless it's
    /// one Safari names (`isKnown`).
    static let gap: CGFloat = 4
    /// The Favourites bar's identifier. Its description ("Favourites Bar") is translated, so it plays
    /// no part.
    static let favoritesBarIdentifier = "FavoritesBarView"

    /// The bars Safari shows between the top of the window at `windowFrame` and the page, top first.
    /// Empty if Safari reports none: the caller keeps its own distance from the top then.
    ///
    /// - A bar is a direct child of the window, or of the split group that holds the page, that is
    ///   wider than it is tall and under `maximumHeight` tall. Never the window's buttons, a sheet,
    ///   the page or the divider beside Safari's sidebar.
    /// - It has to be shown: starting at or below the window's top, within its top `reach`. Safari's
    ///   full-screen toolbar, slid up out of sight or on its way, isn't.
    /// - Bars stack down from the first one: each further one starts where the one above ends,
    ///   within `gap`. So the find bar, which nothing else identifies, counts when it sits below the
    ///   other bars, and nothing lower down does. The toolbar, the Favourites bar and the tab bar
    ///   count wherever they start, by their role or identifier.
    ///
    /// Only the split group's children are read, never the toolbar's or the page's.
    static func bars<Node: SafariBarNode>(among windowChildren: [Node], windowFrame: CGRect) -> [SafariBar] {
        var candidates: [(bar: SafariBar, known: Bool)] = []
        func consider(_ node: Node, known: Bool) {
            guard let frame = node.frame,
                  frame.height > 0, frame.height < maximumHeight, frame.width > frame.height,
                  frame.minY >= windowFrame.minY - 1, frame.minY < windowFrame.minY + reach else { return }
            candidates.append((SafariBar(role: node.role, identifier: node.identifier, frame: frame), known))
        }
        for child in windowChildren {
            switch child.role {
            case "AXSplitGroup":
                // The page, Safari's sidebar and the divider between them, and in the separate tab layout
                // the tab bar above the page.
                for inner in child.children() where inner.role != "AXTabGroup" && inner.role != "AXSplitter" {
                    consider(inner, known: isTabBarIdentifier(inner.identifier))
                }
            case "AXButton", "AXSheet":
                continue
            default:
                consider(child, known: isKnown(role: child.role, identifier: child.identifier))
            }
        }
        var bars: [SafariBar] = []
        var bottom: CGFloat?
        for (bar, known) in candidates.sorted(by: { $0.bar.frame.minY < $1.bar.frame.minY }) {
            if let bottom, !known, bar.frame.minY > bottom + gap {
                continue
            }
            bars.append(bar)
            bottom = max(bottom ?? bar.frame.maxY, bar.frame.maxY)
        }
        return bars
    }

    /// The bottom edge of the lowest bar, in Accessibility coordinates, or nil if there are none.
    static func bottom(of bars: [SafariBar]) -> CGFloat? {
        bars.map(\.frame.maxY).max()
    }

    /// Bars Safari names: the toolbar (and the old tab bar's role, `AXTabGroup`, which the page's
    /// group under the split group also has, so only directly in the window), the Favourites bar
    /// and the tab bar.
    static func isKnown(role: String?, identifier: String?) -> Bool {
        role == "AXToolbar" || role == "AXTabGroup" || identifier == favoritesBarIdentifier || isTabBarIdentifier(identifier)
    }

    /// `TabBar?isSeparate=…`, the way TabBarFinder finds the tab bar.
    static func isTabBarIdentifier(_ identifier: String?) -> Bool {
        TabBarFinder.isTabBarIdentifier(identifier)
    }

    /// For the log: each bar's role, identifier up to its first `?`, and its top and bottom measured
    /// down from `windowTop`.
    static func summary(_ bars: [SafariBar], windowTop: CGFloat) -> String {
        guard !bars.isEmpty else { return "none" }
        return bars.map { bar in
            let identifier = bar.identifier.map { " " + $0.prefix { $0 != "?" } } ?? ""
            let top = Int((bar.frame.minY - windowTop).rounded())
            let bottom = Int((bar.frame.maxY - windowTop).rounded())
            return "\(bar.role ?? "?")\(identifier) \(top)–\(bottom)"
        }.joined(separator: ", ")
    }
}
