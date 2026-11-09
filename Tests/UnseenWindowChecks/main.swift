import CoreGraphics
import Foundation

// Checks for listing a window's tabs from its tab bar, for a window the extension can't see (#41):
// TabBarFinder.tabs and closeAction, and presses made from what was read. Run against the recorded trees in
// ../TabBarFinderChecks/trees. No Safari involved.
//
//   compact-window.json, compact-fullscreen.json   Safari 26 (#20): 30 tabs "Test tab N", the third selected,
//                                                  each with a "Name:close tab" action.
//   window-personal-minimized-real.json            Safari 27 (#28): 4 tabs, all "<tab>" (titles removed), the
//                                                  fourth selected, with Safari 27's close action.
//   window-personal-test-page.json, window-work-new-window-start-page.json
//                                                  A window's only tab: selected, no close action.
//   window-private.json                            A private window with one tab: no tab bar to read.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

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
        case role, subrole, identifier, title, x, value, actions, frame
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
        // Safari 26's trees give `x`; #28's give a frame.
        x = try values.decodeIfPresent(CGFloat.self, forKey: .x)
            ?? (try? values.decodeIfPresent([CGFloat].self, forKey: .frame))?.first
        value = try? values.decodeIfPresent(Int.self, forKey: .value)
        actions = try values.decodeIfPresent([String].self, forKey: .actions) ?? []
        kids = try values.decodeIfPresent([RecordedNode].self, forKey: .kids) ?? []
    }

    func children() -> [RecordedNode] { kids }
}

let treesFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "TabBarFinderChecks/trees")

func tree(_ name: String) -> RecordedNode {
    do {
        return try JSONDecoder().decode(RecordedNode.self, from: Data(contentsOf: treesFolder.appending(path: "\(name).json")))
    } catch {
        print("FAIL: can't read tree \(name): \(error)")
        exit(1)
    }
}

func bar(_ name: String) -> RecordedNode? {
    TabBarFinder.tabBar(in: tree(name))
}

// MARK: - The tabs, in order, and the selected one

for name in ["compact-window", "compact-fullscreen"] {
    guard let bar = bar(name) else {
        check(false, "\(name): no tab bar")
        continue
    }
    let tabs = TabBarFinder.tabs(in: bar)
    check(tabs.map(\.title) == (1...30).map { "Test tab \($0)" }, "\(name): the 30 titles, left to right")
    check(tabs.indices.filter { tabs[$0].isSelected == true } == [2], "\(name): the third selected, and only it")
}

if let bar = bar("window-personal-minimized-real") {
    let tabs = TabBarFinder.tabs(in: bar)
    check(tabs.count == 4 && tabs.allSatisfy { $0.title == "<tab>" }, "Safari 27: four tabs")
    check(tabs.map(\.isSelected) == [false, false, false, true], "the fourth selected")
} else {
    check(false, "Safari 27's window: no tab bar")
}

for name in ["window-personal-test-page", "window-work-new-window-start-page"] {
    if let bar = bar(name) {
        let tabs = TabBarFinder.tabs(in: bar)
        check(tabs.count == 1 && tabs[0].isSelected == true, "\(name): its only tab, selected")
    } else {
        check(false, "\(name): no tab bar")
    }
}
check(bar("window-private") == nil, "the recorded private window has no tab bar to read")

// MARK: - Closing where Safari offers it

if let bar = bar("window-personal-minimized-real") {
    let buttons = TabBarFinder.buttons(in: bar)
    check(buttons.allSatisfy { TabBarFinder.closeAction(among: $0.node.actions)?.contains("_closeButtonClicked:") == true },
          "Safari 27's tab buttons offer their close action")
}
if let bar = bar("compact-window") {
    check(TabBarFinder.buttons(in: bar).allSatisfy { TabBarFinder.closeAction(among: $0.node.actions) == "Name:close tab" }, "Safari 26's too, by name")
}
if let bar = bar("window-personal-test-page") {
    check(TabBarFinder.buttons(in: bar).allSatisfy { TabBarFinder.closeAction(among: $0.node.actions) == nil }, "a window's only tab offers none")
}
check(TabBarFinder.closeAction(among: ["AXPress", "Name:Tab schließen\nTarget:0x1\nSelector:_closeButtonClicked:"]) != nil, "found by its selector in any language")
check(TabBarFinder.closeAction(among: ["AXPress", "AXShowMenu", "Name:Move next\nTarget:0x0\nSelector:(null)"]) == nil, "no other action is taken for it")

// MARK: - Pressing a tab from what was read

if let bar = bar("compact-window") {
    let buttons = TabBarFinder.buttons(in: bar)
    let titles = TabBarFinder.tabs(in: bar).map(\.title)
    if case .press(let node) = TabBarFinder.choose(TabBarTarget(title: titles[9], position: 9, windowTitles: titles), among: buttons) {
        check(node.title == "Test tab 10", "a press on the 10th tab read presses its button")
    } else {
        check(false, "the 10th tab read isn't pressed")
    }
    check(TabBarFinder.choose(TabBarTarget(title: titles[2], position: 2, windowTitles: titles), among: buttons) == .alreadySelected, "the selected one isn't pressed")
}
if let bar = bar("window-personal-minimized-real") {
    let buttons = TabBarFinder.buttons(in: bar)
    let titles = TabBarFinder.tabs(in: bar).map(\.title)
    // Every title is the same here, so only the place tells them apart, and the read lines up with the bar.
    if case .press = TabBarFinder.choose(TabBarTarget(title: titles[1], position: 1, windowTitles: titles), among: buttons) {} else {
        check(false, "tabs with the same title are pressed by place, from a read of the same bar")
    }
}

extension TabBarChoice: Equatable where Node == RecordedNode {
    static func == (lhs: TabBarChoice<Node>, rhs: TabBarChoice<Node>) -> Bool {
        switch (lhs, rhs) {
        case (.alreadySelected, .alreadySelected): true
        case (.press(let a), .press(let b)): a.title == b.title && a.x == b.x
        case (.fallback(let a), .fallback(let b)): a == b
        default: false
        }
    }
}

if failures > 0 {
    print("\(failures) unseen window check(s) failed")
    exit(1)
}
print("unseen window checks passed")
