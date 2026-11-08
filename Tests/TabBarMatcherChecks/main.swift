import Foundation

// Checks for which tab-bar button the matcher picks (#18), against fixture tab bars.
//
// The fixtures model the buttons of a Safari window's tab bar: one radio button per tab, titled with
// the page title, left to right. They are not dumps from a live Safari. When a live run falls back
// on a tab bar that should have matched (the log gives the reason, never the titles), add its
// layout here. (Finding the bar in the window, from recorded trees, is checked in TabBarFinderChecks.)

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

/// A tab bar whose buttons are titled `titles`, 120 points wide from x = 100, in the order given.
func bar(_ titles: [String?]) -> [TabBarItem] {
    titles.enumerated().map { TabBarItem(title: $1, x: 100 + CGFloat($0) * 120) }
}

func target(_ titles: [String?], at position: Int) -> TabBarTarget {
    TabBarTarget(title: titles[position], position: position, windowTitles: titles)
}

func match(_ tabs: [String?], at position: Int, bar buttons: [TabBarItem]) -> TabBarMatch {
    TabBarMatcher.match(target(tabs, at: position), items: buttons)
}

let five: [String?] = ["Inbox", "GitHub", "Docs", "News", "Maps"]

// MARK: - The usual case

for position in five.indices {
    check(match(five, at: position, bar: bar(five)) == .press(position), "tab \(position) is found where it sits")
}

// MARK: - Buttons listed in another order than they're drawn

do {
    // Safari lists them shuffled, but they carry their positions.
    var shuffled = bar(five)
    shuffled.swapAt(0, 3)
    shuffled.swapAt(1, 4)
    let result = match(five, at: 2, bar: shuffled)
    guard case .press(let index) = result else { fatalError("expected a press, got \(result)") }
    check(shuffled[index].title == "Docs", "the button is picked by where it's drawn, not where it's listed")
    check(shuffled[index].x == 100 + 2 * 120, "and it's the third from the left")
}

do {
    // Without positions the order given is taken as left to right.
    let unpositioned = five.map { TabBarItem(title: $0, x: nil) }
    check(match(five, at: 3, bar: unpositioned) == .press(3), "without positions, the order given is used")
}

// MARK: - Not sure, so fall back

func isFallback(_ result: TabBarMatch) -> Bool {
    if case .fallback = result { return true }
    return false
}

check(isFallback(match(five, at: 1, bar: [])), "no tab bar: fall back (a window with one tab hides it)")
check(isFallback(TabBarMatcher.match(TabBarTarget(title: nil, position: 0, windowTitles: [nil]), items: bar(["Page"]))),
      "a tab with no title can't be recognised")
check(isFallback(TabBarMatcher.match(TabBarTarget(title: "  \n ", position: 0, windowTitles: ["  \n "]), items: bar(["Page"]))),
      "nor can one whose title is blank")

do {
    // The tab was renamed (page changed its title) and the sidebar hasn't heard yet.
    var renamed = five
    renamed[2] = "Docs (3 new)"
    check(isFallback(match(five, at: 2, bar: bar(renamed))), "a button with a different title is not the tab")
}

do {
    // Same title twice: neighbours decide.
    let twins: [String?] = ["Inbox", "Google", "Docs", "Google", "Maps"]
    check(match(twins, at: 1, bar: bar(twins)) == .press(1), "two tabs with one title: the first, neighbours agree")
    check(match(twins, at: 3, bar: bar(twins)) == .press(3), "two tabs with one title: the second, neighbours agree")

    // The user moved a tab in the sidebar and Safari hasn't caught up: the order differs by a swap.
    var behind = twins
    behind.swapAt(0, 2)           // Safari's bar: Docs, Google, Inbox, Google, Maps
    check(isFallback(match(twins, at: 1, bar: bar(behind))), "twins whose neighbours moved are not trusted")

    let adjacent: [String?] = ["Google", "Google", "Docs"]
    check(match(adjacent, at: 0, bar: bar(adjacent)) == .press(0), "twins at the left end: the one neighbour agrees")
    var wrongOrder = adjacent
    wrongOrder[2] = "News"
    check(isFallback(match(adjacent, at: 1, bar: bar(wrongOrder))), "twins with a neighbour that differs are not trusted")

    // A neighbour with no title can't vouch for anything.
    let untitled: [String?] = [nil, "Google", "Google"]
    check(isFallback(match(untitled, at: 1, bar: bar([nil, "Google", "Google"]))), "twins next to an untitled tab are not trusted")
}

// MARK: - The bar and the window disagree about how many tabs there are

do {
    // The sidebar still lists a tab that was just closed; the bar has one fewer.
    var closed = five
    closed.remove(at: 1)
    check(match(five, at: 3, bar: bar(closed)) == .press(2), "a unique title is still found when counts differ")
    check(isFallback(match(five, at: 1, bar: bar(closed))), "a tab that's gone from the bar is not pressed")

    // A "+" button after the tabs.
    let withPlus = bar(five + ["Open a new tab"])
    check(match(five, at: 4, bar: withPlus) == .press(4), "an extra button after the tabs doesn't hide a unique title")

    // Tabs scrolled out of view that Safari doesn't list.
    let ten: [String?] = (1...10).map { "Page \($0)" }
    let visible = bar(Array(ten[3...8]))
    check(match(ten, at: 5, bar: visible) == .press(2), "tabs missing from the bar: a unique title is found")
    check(isFallback(match(ten, at: 0, bar: visible)), "a tab that's scrolled out of view is not pressed")

    // The same, with a title another tab shares.
    var shared = ten
    shared[5] = "Page 9"
    check(isFallback(match(shared, at: 5, bar: bar(Array(shared[3...8])))), "counts differ and the title isn't unique: fall back")
}

do {
    // Order disagrees (a reorder in flight) but the title is unique: still the right tab.
    var reordered = five
    reordered.swapAt(0, 4)        // Maps, GitHub, Docs, News, Inbox
    check(match(five, at: 4, bar: bar(reordered)) == .press(0), "a unique title is found even when the order differs")
}

// MARK: - Spelling

do {
    check(match(["Caf\u{65}\u{301}", "B"], at: 0, bar: bar(["Caf\u{E9}", "B"])) == .press(0),
          "accented letters compare equal whichever way they're composed")
    check(match(["News  \n today", "B"], at: 0, bar: bar([" News today ", "B"])) == .press(0),
          "whitespace differences don't matter")
    check(isFallback(match(["News", "B"], at: 0, bar: bar(["news", "B"]))), "case does")
}

do {
    check(isFallback(TabBarMatcher.match(TabBarTarget(title: "A", position: 7, windowTitles: ["A", "B"]), items: bar(["A", "B"]))
        ) == false, "a stale position still resolves by unique title")
    check(isFallback(TabBarMatcher.match(TabBarTarget(title: "A", position: 7, windowTitles: ["A", "A"]), items: bar(["A", "A"]))),
          "a stale position with twin titles falls back")
}

// MARK: - Which tab Safari has selected (#22 item 2)

/// `bar(titles)` with the button at `selected` marked as the selected tab's, the others as not.
func barSelecting(_ selected: Int?, _ titles: [String?]) -> [TabBarItem] {
    var buttons = bar(titles)
    for index in buttons.indices {
        buttons[index].isSelected = selected.map { $0 == index }
    }
    return buttons
}

func isUnknown(_ selection: TabBarSelection) -> Bool {
    if case .unknown = selection { return true }
    return false
}

do {
    for position in five.indices {
        check(TabBarMatcher.selection(among: barSelecting(position, five), windowTitles: five) == .tab(position: position),
              "the selected button is the tab at its place (\(position))")
    }

    // Listed in another order than drawn: the place is where it's drawn.
    var shuffled = barSelecting(2, five)
    shuffled.swapAt(0, 3)
    shuffled.swapAt(1, 4)
    check(TabBarMatcher.selection(among: shuffled, windowTitles: five) == .tab(position: 2), "by where it is drawn, not where it is listed")

    check(isUnknown(TabBarMatcher.selection(among: barSelecting(nil, five), windowTitles: five)),
          "buttons that say nothing about being selected say nothing")
    var two = barSelecting(1, five)
    two[3].isSelected = true
    check(isUnknown(TabBarMatcher.selection(among: two, windowTitles: five)), "two selected buttons can't both be right")
    var none = barSelecting(1, five)
    none[1].isSelected = false
    check(isUnknown(TabBarMatcher.selection(among: none, windowTitles: five)), "and none selected says nothing")
    check(isUnknown(TabBarMatcher.selection(among: [], windowTitles: five)), "no buttons, no answer")
}

do {
    // The sidebar's tabs and Safari's differ: not sure which is meant, so nothing is said.
    check(isUnknown(TabBarMatcher.selection(among: barSelecting(1, five), windowTitles: Array(five.dropLast()))),
          "more buttons than tabs: the sidebar hasn't heard of a tab, so the place means nothing")
    check(isUnknown(TabBarMatcher.selection(among: barSelecting(1, Array(five.dropLast())), windowTitles: five)),
          "fewer buttons than tabs: the same")
    var renamed = five
    renamed[1] = "Something else"
    check(isUnknown(TabBarMatcher.selection(among: barSelecting(1, five), windowTitles: renamed)),
          "the selected tab's title differs from the sidebar's: not sure it is that tab")
    check(TabBarMatcher.selection(among: barSelecting(1, five), windowTitles: ["Inbox", "GitHub", "Docs", "Other", "Maps"]) == .tab(position: 1),
          "a title that differs elsewhere in the bar doesn't matter when the selected tab's own title is unique")
    check(isUnknown(TabBarMatcher.selection(among: barSelecting(1, five), windowTitles: [nil, nil, nil, nil, nil])),
          "tabs without titles can't be recognised")
}

do {
    // Twin titles: the neighbours have to agree, as for a press.
    let twins: [String?] = ["A", "Same", "Same", "B"]
    check(TabBarMatcher.selection(among: barSelecting(1, twins), windowTitles: twins) == .tab(position: 1),
          "twins are told apart by their place when the neighbours agree")
    check(TabBarMatcher.selection(among: barSelecting(2, twins), windowTitles: twins) == .tab(position: 2), "both of them")
    check(isUnknown(TabBarMatcher.selection(among: barSelecting(1, ["A", "Same", "Same", "B"]), windowTitles: ["Z", "Same", "Same", "B"])),
          "but not when a neighbour differs: the order may be a moment behind")
}

if failures == 0 {
    print("tab bar matcher checks passed")
} else {
    print("\(failures) tab bar matcher check(s) failed")
    exit(1)
}
