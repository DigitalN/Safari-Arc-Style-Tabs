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
// Every tab button carries `value`, Safari 26's `AXValue`: 1 on the selected tab's button, 0 on the
// others (measured in #22; there is no AXSelected). The values in the files are written to match
// that, with the button that holds the address field (the one with children) as the selected one.
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
    var value: Int?
    var actions: [String]
    var kids: [RecordedNode]

    enum CodingKeys: String, CodingKey {
        case role, subrole, identifier, title, x, value, actions
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
        value = try values.decodeIfPresent(Int.self, forKey: .value)
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
            case .alreadySelected:
                check(number == 3, "only the third tab, which Safari shows, is left alone; tab \(number) should be pressed")
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

// MARK: - The selected tab (#22 item 1)

do {
    // In the recorded window the third tab is the selected one: Safari already shows it, so it isn't pressed.
    if let bar = found("compact-window") {
        let buttons = TabBarFinder.buttons(in: bar)
        check(buttons.map(\.item.isSelected) == (1...30).map { $0 == 3 }, "exactly the third button is read as selected")
        if case .alreadySelected = TabBarFinder.choose(target(3), among: buttons) {} else {
            check(false, "the selected tab's button must not be pressed")
        }
        if case .press(let node) = TabBarFinder.choose(target(4), among: buttons) {
            check(node.title == "Test tab 4", "any other tab is pressed on its own button")
        } else {
            check(false, "a tab that isn't selected should be pressed")
        }
    }
    // Full screen and the separate layout read it the same way.
    if let bar = found("compact-fullscreen") {
        check(TabBarFinder.buttons(in: bar).filter { $0.item.isSelected == true }.count == 1, "one selected button in full screen")
    }
    if let bar = found("constructed-separate") {
        let buttons = TabBarFinder.buttons(in: bar)
        if case .alreadySelected = TabBarFinder.choose(target(2, of: 5), among: buttons) {} else {
            check(false, "the separate layout's selected tab is not pressed")
        }
    }
    // A Safari that doesn't report AXValue: nothing says a tab is selected, so the tab is pressed as before.
    if let bar = found("constructed-no-value") {
        let buttons = TabBarFinder.buttons(in: bar)
        check(buttons.allSatisfy { $0.item.isSelected == nil }, "a button without AXValue says nothing about being selected")
        if case .press(let node) = TabBarFinder.choose(target(2, of: 5), among: buttons) {
            check(node.title == "Test tab 2", "so even the tab that is selected is pressed on its own button")
        } else {
            check(false, "without AXValue the tab should be pressed")
        }
    }
    // A number that isn't 0 or 1 isn't understood either, and says nothing.
    let odd = #"{"role":"AXOpaqueProviderGroup","identifier":"TabBar?","children":[{"role":"AXRadioButton","value":2,"title":"A","actions":["AXPress"]},{"role":"AXRadioButton","value":0,"title":"B","actions":["AXPress"]}]}"#
    if let bar = try? JSONDecoder().decode(RecordedNode.self, from: Data(odd.utf8)) {
        check(TabBarFinder.buttons(in: bar).map(\.item.isSelected) == [nil, false], "a value other than 0 or 1 says nothing")
    } else {
        check(false, "the inline tree should decode")
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
