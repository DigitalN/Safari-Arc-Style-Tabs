import CoreGraphics
import Foundation

// Checks for finding the tab or bookmark row under a point (RowHitTesting.swift), which is how a
// middle click is matched to a row (#21 item 1, #25).

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

func key(_ id: Int) -> TabKey { TabKey(instance: "i", tabId: id) }

/// Rows 30 high with 1 between them from y = 100, 240 wide from x = 8, in a list showing y = 60...400.
func rows(_ count: Int) -> SidebarRows {
    let rows = SidebarRows()
    rows.viewport = CGRect(x: 0, y: 60, width: 260, height: 340)
    for index in 0..<count {
        rows.setFrame(CGRect(x: 8, y: 100 + CGFloat(index) * 31, width: 240, height: 30), for: key(index + 1))
    }
    return rows
}

do {
    let list = rows(5)
    check(list.tab(at: CGPoint(x: 100, y: 115)) == key(1), "a point in the first row is the first row")
    check(list.tab(at: CGPoint(x: 100, y: 100 + 31 * 3 + 29)) == key(4), "and near the bottom of the fourth is the fourth")
    check(list.tab(at: CGPoint(x: 247, y: 115)) == key(1), "right up to the row's edge")
    check(list.tab(at: CGPoint(x: 100, y: 130.5)) == nil, "the gap between two rows is neither")
    check(list.tab(at: CGPoint(x: 4, y: 115)) == nil, "the margin beside the rows is not a row")
    check(list.tab(at: CGPoint(x: 100, y: 80)) == nil, "above the first row is not a row")
    check(list.tab(at: CGPoint(x: 100, y: 300)) == nil, "below the last row is not a row")
}

do {
    // Rows scrolled out of the list keep their frames, which lie over the address bar above it.
    let list = rows(5)
    list.setFrame(CGRect(x: 8, y: 20, width: 240, height: 30), for: key(6))
    check(list.tab(at: CGPoint(x: 100, y: 30)) == nil, "a row scrolled up under the address bar can't be hit there")
    list.setFrame(CGRect(x: 8, y: 390, width: 240, height: 30), for: key(7))
    check(list.tab(at: CGPoint(x: 100, y: 410)) == nil, "nor one scrolled below the list's bottom edge")
    check(list.tab(at: CGPoint(x: 100, y: 395)) == key(7), "but the part of a row that's showing can")
}

do {
    // Frames follow the rows.
    let list = rows(3)
    list.setFrame(CGRect(x: 8, y: 300, width: 240, height: 30), for: key(3))
    check(list.tab(at: CGPoint(x: 100, y: 315)) == key(3), "a row that moved is found where it is now")
    check(list.tab(at: CGPoint(x: 100, y: 100 + 31 * 2 + 15)) == nil, "and not where it was")
    list.remove(key(3))
    check(list.tab(at: CGPoint(x: 100, y: 315)) == nil, "a removed row isn't found")
    check(SidebarRows().tab(at: CGPoint(x: 100, y: 115)) == nil, "with nothing known, nothing is hit (a list that hasn't reported its size)")
}

do {
    // Bookmark rows are found too, so a middle click on an open bookmark closes its tab (#25).
    let list = rows(2)
    let id = UUID()
    list.setFrame(CGRect(x: 8, y: 300, width: 240, height: 30), forBookmark: id)
    check(list.bookmark(at: CGPoint(x: 100, y: 315)) == id, "a point on a bookmark row is that bookmark")
    check(list.tab(at: CGPoint(x: 100, y: 315)) == nil, "and not a tab")
    check(list.bookmark(at: CGPoint(x: 100, y: 115)) == nil, "a point on a tab row is no bookmark")
    list.setFrame(CGRect(x: 8, y: 20, width: 240, height: 30), forBookmark: id)
    check(list.bookmark(at: CGPoint(x: 100, y: 30)) == nil, "a bookmark row scrolled up under the address bar can't be hit there")
    list.setFrame(CGRect(x: 8, y: 300, width: 240, height: 30), forBookmark: id)
    list.removeBookmark(id)
    check(list.bookmark(at: CGPoint(x: 100, y: 315)) == nil, "a removed bookmark row isn't found")
}

if failures == 0 {
    print("row hit checks passed")
} else {
    print("\(failures) row hit check(s) failed")
    exit(1)
}
