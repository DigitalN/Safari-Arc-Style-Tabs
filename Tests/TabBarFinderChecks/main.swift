import CoreGraphics
import Foundation

// Checks for finding Safari's tab bar and the button for a tab (TabBarFinder.swift), run against
// trees of Safari's windows kept as data in trees/. No Safari involved.
//
//   compact-*.json        What #20 recorded in Safari 26 (compact tab layout, 30 tabs, the third
//                         active): in a window, in full screen, and "right after the window opened",
//                         when the last tab's button had no title and no actions.
//   constructed-*.json    Made up for a case nobody has recorded (the separate tab layout, a window
//                         with no tab bar, labels that mustn't be trusted). Not Safari output.
//
// When the live app logs a window the finder gets wrong (the tab-bar diagnostics name the
// elements it looked through), add that tree here.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

/// Which elements the search read the children of, as `role#identifier`. Reading costs a round
/// trip to Safari, so the search should not read what it has no use for.
nonisolated(unsafe) var reads: [String] = []

struct RecordedNode: Decodable, TabBarNode {
    var role: String?
    var subrole: String?
    var identifier: String?
    var title: String?
    var descriptionText: String?
    var x: CGFloat?
    var actions: [String]
    var kids: [RecordedNode]

    enum CodingKeys: String, CodingKey {
        case role, subrole, identifier, title, x, actions
        case descriptionText = "description"
        case kids = "children"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decodeIfPresent(String.self, forKey: .role)
        subrole = try values.decodeIfPresent(String.self, forKey: .subrole)
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        descriptionText = try values.decodeIfPresent(String.self, forKey: .descriptionText)
        x = try values.decodeIfPresent(CGFloat.self, forKey: .x)
        actions = try values.decodeIfPresent([String].self, forKey: .actions) ?? []
        kids = try values.decodeIfPresent([RecordedNode].self, forKey: .kids) ?? []
    }

    func children() -> [RecordedNode] {
        reads.append("\(role ?? "?")#\(identifier ?? "")")
        return kids
    }
}

let treesFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "trees")

func tree(_ name: String) -> RecordedNode {
    do {
        return try JSONDecoder().decode(RecordedNode.self, from: Data(contentsOf: treesFolder.appending(path: "\(name).json")))
    } catch {
        print("FAIL: can't read tree \(name): \(error)")
        exit(1)
    }
}

/// A target for the tab with this number, in a window of `count` tabs titled "Test tab N".
func target(_ number: Int, of count: Int = 30) -> TabBarTarget {
    TabBarTarget(title: "Test tab \(number)", position: number - 1, windowTitles: (1...count).map { "Test tab \($0)" })
}

func found(_ name: String) -> RecordedNode? {
    reads = []
    return TabBarFinder.tabBar(in: tree(name))
}

// MARK: - A window (recorded)

do {
    let bar = found("compact-window")
    check(bar?.identifier == "TabBar?isSeparate=false", "the tab bar is found by its identifier: \(bar?.identifier ?? "nil")")
    check(bar?.subrole == "AXOpaqueProviderList", "and it's the list, not the page's AXTabGroup")
    check(bar?.role != "AXTabGroup", "the page's AXTabGroup is never taken")
    check(!reads.contains { $0.hasPrefix("AXTabGroup") || $0.hasPrefix("AXWebArea") || $0.contains("BrowserView") },
          "and the page isn't read while looking: \(reads)")
    check(!reads.contains { $0.hasPrefix("AXRadioButton") }, "nor the tabs")

    if let bar {
        let buttons = TabBarFinder.buttons(in: bar)
        check(buttons.count == 30, "all 30 tab buttons are read: \(buttons.count)")
        check(buttons.allSatisfy { $0.node.identifier?.hasPrefix("TabBarTab?") == true }, "only the tabs' buttons")
        for number in 1...30 {
            switch TabBarFinder.choose(target(number), among: buttons) {
            case .press(let node):
                check(node.title == "Test tab \(number)", "tab \(number) is pressed on its own button, not \(node.title ?? "nil")")
            case .fallback(let reason):
                check(false, "tab \(number) should be pressed, fell back: \(reason)")
            }
        }
    }
}

// MARK: - Full screen (recorded): one level deeper

do {
    let bar = found("compact-fullscreen")
    check(bar?.identifier == "TabBar?isSeparate=false", "in full screen the tab bar is found too: \(bar?.identifier ?? "nil")")
    check(TabBarFinder.searchDepth >= 4, "the search reaches window → group → toolbar → group → tab bar")
    check(!reads.contains { $0.hasPrefix("AXTabGroup") || $0.hasPrefix("AXWebArea") }, "without reading the page: \(reads)")
    if let bar {
        check(TabBarFinder.buttons(in: bar).count == 30, "and its 30 buttons are read")
    }
}

// MARK: - The last tab's odd button (recorded)

do {
    // Right after a window opened, tab 30's button had no title (only a description), no children, no actions.
    let bar = found("compact-window-fresh")
    check(bar != nil, "the tab bar is found as usual")
    if let bar {
        let buttons = TabBarFinder.buttons(in: bar)
        check(buttons.count == 30, "the odd button is still one of the 30")
        check(buttons.last?.item.title == "Test tab 30", "its title is read from the description")
        if case .fallback(let reason) = TabBarFinder.choose(target(30), among: buttons) {
            check(reason.contains("press"), "a button without AXPress is not pressed: \(reason)")
        } else {
            check(false, "a button without AXPress must fall back at once")
        }
        if case .press(let node) = TabBarFinder.choose(target(29), among: buttons) {
            check(node.title == "Test tab 29", "the buttons next to it still work")
        } else {
            check(false, "tab 29 should still be pressed")
        }
    }
}

// MARK: - No tab bar

do {
    check(found("constructed-no-tab-bar") == nil, "a window without a tab bar (one tab) has none: the page's AXTabGroup isn't taken instead")
    check(found("constructed-page-decoy") == nil, "an element labelled like the bar inside the page's AXTabGroup isn't found")
    check(!reads.contains { $0.hasPrefix("AXTabGroup") }, "because the page's AXTabGroup isn't entered: \(reads)")
    check(found("constructed-too-deep") == nil, "one more level down than a full screen window is out of reach, not searched for forever")
    check(found("constructed-tab-group-layout") == nil, "a tab bar that is an AXTabGroup, like the page's, can't be told from it: no tab bar, so fall back")
}

// MARK: - Labels that mustn't be trusted

do {
    let german = found("constructed-localized")
    check(german?.identifier == "TabBar?isSeparate=false", "a translated description changes nothing: found by identifier")
    check(found("constructed-description-only") == nil, "a group that only says \"Tab bar\" in its description isn't taken: it's translated")
    check(found("constructed-subrole-only")?.subrole == "AXOpaqueProviderList", "without an identifier, the list's subrole finds it")
    check(found("constructed-two-lists")?.identifier == "TabBar?isSeparate=false", "a labelled tab bar beats another list with the same subrole")
}

// MARK: - The separate tab layout (not recorded)

do {
    let bar = found("constructed-separate")
    check(bar?.identifier == "TabBar?isSeparate=true", "the separate layout is found if it uses the same identifier: \(bar?.identifier ?? "nil")")
    if let bar {
        check(TabBarFinder.buttons(in: bar).count == 5, "and its buttons are read")
    }
}

// MARK: - Identifiers

check(TabBarFinder.isTabBar(identifier: "TabBar?isSeparate=false", subrole: nil), "TabBar? is the tab bar")
check(TabBarFinder.isTabBar(identifier: "TabBar", subrole: nil), "so is a plain TabBar")
check(!TabBarFinder.isTabBar(identifier: "TabBarTab?isNarrow=true", subrole: "AXTabButton"), "a tab's own button, whose identifier starts the same way, is not")
check(!TabBarFinder.isTabBar(identifier: "BrowserView?tab=1", subrole: nil), "the page isn't")
check(TabBarFinder.isTabBar(identifier: nil, subrole: "AXOpaqueProviderList"), "the list subrole is")
check(!TabBarFinder.isTabBar(identifier: nil, subrole: nil), "an element with neither isn't")

if failures == 0 {
    print("tab bar finder checks passed")
} else {
    print("\(failures) tab bar finder check(s) failed")
    exit(1)
}
