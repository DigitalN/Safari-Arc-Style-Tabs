import CoreGraphics
import Foundation

// Checks for where the sidebar goes when it isn't docked, and when it slides out and away
// (SidebarOverlay.swift). Moving the panel, reading the pointer and Safari's window need the running
// app; these cover the rules DockController follows.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

// MARK: - Docked or overlay

check(SidebarPlacement.choose(fullScreen: false, hidesAutomatically: false) == .docked,
      "a normal window with the setting off: docked, as before")
check(SidebarPlacement.choose(fullScreen: false, hidesAutomatically: true) == .overlay(.window),
      "a normal window with the setting on: the overlay at the window's edge")
check(SidebarPlacement.choose(fullScreen: true, hidesAutomatically: false) == .overlay(.fullScreen),
      "full screen with the setting off: the full-screen overlay, as before")
check(SidebarPlacement.choose(fullScreen: true, hidesAutomatically: true) == .overlay(.fullScreen),
      "full screen with the setting on: still the full-screen overlay")

// MARK: - Full-screen layout

// The layout DockController.layOutOverlay worked out before the setting existed, transcribed. It kept
// the 60-point floor even below a shorter toolbar Safari reported; since #35 the floor applies only
// when Safari reports no bars, so the two agree when it reports none or bars taller than 60 points.
func oldFullScreenPanel(screen: CGRect, toolbarBottom: CGFloat?, mainHeight: CGFloat, width: CGFloat) -> CGRect {
    let inset: CGFloat = 8
    let minimumToolbar: CGFloat = 60
    let screenTop = mainHeight - screen.maxY
    let toolbarBottom = max(toolbarBottom ?? 0, screenTop + minimumToolbar)
    let top = mainHeight - toolbarBottom - inset
    let bottom = screen.minY + inset
    return CGRect(x: screen.minX + inset, y: bottom, width: width, height: max(top - bottom, 200)).integral
}

let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
let besideRight = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
let above = CGRect(x: 200, y: 982, width: 1280, height: 720)
for screen in [laptop, besideRight, above] {
    let screenTop = laptop.height - screen.maxY
    for toolbar: CGFloat? in [nil, screenTop + 97.5, screenTop + 900] {
        // The old formula took an unknown toolbar for y 0, the main display's top. On a display above
        // the main one that is below the display's own top, so the panel shrank to its minimum height
        // at the bottom of the screen. Checked below instead.
        if toolbar == nil && screenTop < 0 { continue }
        for width: CGFloat in [180, 260, 333, 420] {
            let layout = OverlayLayout.fullScreen(screen: screen, toolbarBottom: toolbar, mainHeight: laptop.height, width: width)
            let old = oldFullScreenPanel(screen: screen, toolbarBottom: toolbar, mainHeight: laptop.height, width: width)
            check(layout.panel == old, "full screen \(screen), toolbar \(toolbar.map { "\($0)" } ?? "unknown"), width \(width): the panel is where it was (\(layout.panel) vs \(old))")
        }
    }
    // A toolbar shorter than the floor: the panel starts 8 points below it, not 8 below the floor (#35).
    for bars: CGFloat in [20, 52] {
        let layout = OverlayLayout.fullScreen(screen: screen, toolbarBottom: screenTop + bars, mainHeight: laptop.height, width: 260)
        check(layout.panel.maxY == screen.maxY - bars - 8, "full screen \(screen), bars \(bars) points tall: the panel starts 8 below them: \(layout.panel)")
        check(layout.panel.minY == screen.minY + 8 && layout.panel.minX == screen.minX + 8, "and 8 in from the left and bottom, as before")
        check(layout.strip.maxY == screen.maxY - bars, "the strip stops at their bottom: \(layout.strip)")
    }
}

do {
    // Full screen on a display above the main one, with Safari reporting no bars: the floor is
    // measured from that display's top, so the panel runs its whole height below it (#35).
    let layout = OverlayLayout.fullScreen(screen: above, toolbarBottom: nil, mainHeight: laptop.height, width: 260)
    check(layout.panel == CGRect(x: 208, y: 990, width: 260, height: 720 - 60 - 16), "the panel fills the display above below the floor: \(layout.panel)")
    check(layout.strip.maxY == above.maxY - 60, "and the strip stops 60 points below its top: \(layout.strip)")
}

do {
    // The strip is the screen's left edge, within 2 points of it, as before.
    let strip = OverlayLayout.fullScreen(screen: laptop, toolbarBottom: nil, mainHeight: laptop.height, width: 260).strip
    check(strip.contains(CGPoint(x: 0, y: 500)), "the pointer against the screen's left edge brings it out")
    check(strip.contains(CGPoint(x: 2, y: 500)), "so does 2 points in")
    check(!strip.contains(CGPoint(x: 2.5, y: 500)), "but not more")
    check(strip.contains(CGPoint(x: 0, y: 0)), "from the bottom of the screen")
    check(!strip.contains(CGPoint(x: 0, y: -1)), "and no lower")
}

do {
    // #30: a display to the left of the full-screen one. Every point on it is left of the full-screen
    // display's edge; none of them may count as being at it, or the sidebar flickers out and away.
    let layout = OverlayLayout.fullScreen(screen: besideRight, toolbarBottom: nil, mainHeight: laptop.height, width: 260)
    check(layout.strip.contains(CGPoint(x: 1512, y: 300)), "the full-screen display's own left edge still brings it out")
    check(layout.strip.contains(CGPoint(x: 1511, y: 300)), "allowing a point past it for rounding")
    check(!layout.strip.contains(CGPoint(x: 1510.5, y: 300)), "but no further")
    for point in [CGPoint(x: 1000, y: 300), CGPoint(x: 0, y: 300), CGPoint(x: 1500, y: 0), CGPoint(x: 1505, y: 500)] {
        check(!layout.strip.contains(point), "the pointer on the display to the left at \(point) does nothing")
    }
    // The same with the laptop full screen and a display to its left.
    let left = OverlayLayout.fullScreen(screen: laptop, toolbarBottom: nil, mainHeight: laptop.height, width: 260)
    check(!left.strip.contains(CGPoint(x: -800, y: 400)) && !left.strip.contains(CGPoint(x: -2, y: 400)), "nor on one left of the laptop")
}

do {
    // #30: the top-left corner. Pointing at the top slides Safari's toolbar down; the strip stops at
    // the toolbar's bottom, beside the panel, so the corner doesn't bring the sidebar out.
    let unknown = OverlayLayout.fullScreen(screen: laptop, toolbarBottom: nil, mainHeight: laptop.height, width: 260)
    check(unknown.strip.maxY == 982 - 60, "without the toolbar's bottom, the strip stops 60 points below the top")
    check(!unknown.strip.contains(CGPoint(x: 0, y: 982)) && !unknown.strip.contains(CGPoint(x: 0, y: 950)), "the corner does nothing")
    check(unknown.strip.contains(CGPoint(x: 0, y: 922)), "just below the toolbar still does")
    let tall = OverlayLayout.fullScreen(screen: laptop, toolbarBottom: 97.5, mainHeight: laptop.height, width: 260)
    check(tall.strip.maxY == 982 - 97.5, "a taller toolbar keeps the strip lower: \(tall.strip.maxY)")
    check(!tall.strip.contains(CGPoint(x: 0, y: 900)), "beside the toolbar does nothing")
    // On a second display, measured from its own top.
    let external = OverlayLayout.fullScreen(screen: besideRight, toolbarBottom: nil, mainHeight: laptop.height, width: 260)
    check(external.strip.maxY == besideRight.maxY - 60, "on another display the strip stops below that display's toolbar")
    // A toolbar reported lower than the screen goes: the panel keeps its minimum height, and the strip
    // still runs beside it rather than being empty.
    let short = CGRect(x: 0, y: 0, width: 1512, height: 300)
    let odd = OverlayLayout.fullScreen(screen: short, toolbarBottom: laptop.height - 10, mainHeight: laptop.height, width: 260)
    check(odd.strip.minY == 0 && odd.strip.maxY == odd.panel.maxY, "the strip is beside the panel: \(odd.strip), panel \(odd.panel)")
    check(odd.strip.contains(CGPoint(x: 0, y: 100)), "and the edge beside it brings it out")
}

do {
    // Just after the pointer brings the sidebar out it is still on the strip, so all of the strip has
    // to be close enough to the panel to keep it out; otherwise it flickers in and out (#30).
    for screen in [laptop, besideRight, above] {
        let screenTop = laptop.height - screen.maxY
        for toolbar: CGFloat? in [nil, screenTop + 52, screenTop + 97.5, screenTop + 900] {
            let layout = OverlayLayout.fullScreen(screen: screen, toolbarBottom: toolbar, mainHeight: laptop.height, width: 260)
            let kept = layout.panel.insetBy(dx: -OverlayReveal.margin, dy: -OverlayReveal.margin)
            let corners = [
                CGPoint(x: layout.strip.minX, y: layout.strip.minY), CGPoint(x: layout.strip.maxX, y: layout.strip.minY),
                CGPoint(x: layout.strip.minX, y: layout.strip.maxY), CGPoint(x: layout.strip.maxX, y: layout.strip.maxY),
            ]
            check(corners.allSatisfy(kept.contains), "full screen \(screen), toolbar \(toolbar.map { "\($0)" } ?? "unknown"): all of the strip keeps the sidebar out")
        }
    }
}

do {
    // Played through: the pointer on a display to the left, then in the top-left corner, of a
    // full-screen Safari. Neither brings the sidebar out, so neither flickers.
    let layout = OverlayLayout.fullScreen(screen: besideRight, toolbarBottom: nil, mainHeight: laptop.height, width: 260)
    var reveal = OverlayReveal()
    var actions: [OverlayReveal.Action] = []
    for point in [CGPoint(x: 800, y: 300), CGPoint(x: 1505, y: 300), CGPoint(x: 1512, y: besideRight.maxY - 1)] {
        for _ in 0..<5 {
            actions.append(reveal.poll(pointer: point, strip: layout.strip, panel: layout.panel, safariInFront: true, holding: false))
        }
    }
    check(actions.allSatisfy { $0 == .none }, "no flicker: \(actions)")
    // And at the edge beside the panel, it comes out once and stays.
    actions = (0..<5).map { _ in reveal.poll(pointer: CGPoint(x: 1512, y: 300), strip: layout.strip, panel: layout.panel, safariInFront: true, holding: false) }
    check(actions == [.reveal, .none, .none, .none, .none], "out once, and it stays: \(actions)")
}

// MARK: - A window's layout

// Laptop screen, menu bar 33 pt (visible frame up to 949), Dock at the bottom (from 70).
let visible = CGRect(x: 0, y: 70, width: 1512, height: 879)
// A window from x 300 to 1300, y 100 to 800 (AppKit); its top is 182 down from the top in AX terms.
let window = CGRect(x: 300, y: 100, width: 1000, height: 700)
let windowTopAX = laptop.height - window.maxY

do {
    // A 52-point toolbar, Safari's compact one: the panel starts 8 points below it, not below the
    // 60-point floor, which is only for when Safari reports no bars (#35).
    let layout = OverlayLayout.window(frame: window, visible: visible, toolbarBottom: windowTopAX + 52, mainHeight: laptop.height, width: 260)
    // The toolbar ends at AppKit y 748; the panel is 8 pt in from the window's left and bottom and from that.
    check(layout.panel == CGRect(x: 308, y: 108, width: 260, height: 632), "the panel is over the page, 8 below the toolbar: \(layout.panel)")
    check(layout.strip == RevealStrip(minX: 296, maxX: 304, minY: 100, maxY: 748), "the strip is the window's left edge beside the page: \(layout.strip)")
    check(layout.panel.minX > window.minX && layout.panel.maxX < window.maxX, "the panel is inside the window: Safari isn't moved for it")
    check(!layout.strip.contains(CGPoint(x: 302, y: 760)), "the left edge beside the toolbar isn't part of the strip")
    check(!layout.strip.contains(CGPoint(x: 302, y: 99)), "nor below the window")
    check(layout.strip.contains(CGPoint(x: 296, y: 400)) && layout.strip.contains(CGPoint(x: 304, y: 400)), "4 points out of the window and 4 in are")
    check(!layout.strip.contains(CGPoint(x: 295, y: 400)) && !layout.strip.contains(CGPoint(x: 305, y: 400)), "but no more")
    check(!layout.strip.contains(CGPoint(x: 0, y: 400)), "the screen's edge is nowhere near this window: it does nothing")
}

do {
    // A taller toolbar, as with the favorites bar.
    let layout = OverlayLayout.window(frame: window, visible: visible, toolbarBottom: windowTopAX + 110, mainHeight: laptop.height, width: 260)
    check(layout.panel.maxY == 800 - 110 - 8, "the panel starts below however tall the toolbar is")
    check(layout.strip.maxY == 800 - 110, "and so does the strip")
}

do {
    // Safari reported none of its bars: the floor. A bottom at or above the window's top isn't a bar
    // Safari shows, so it's the same.
    let unknown = OverlayLayout.window(frame: window, visible: visible, toolbarBottom: nil, mainHeight: laptop.height, width: 260)
    check(unknown.panel.maxY == 800 - 60 - 8, "without any bars, the panel starts 60 points down the window, and 8 more")
    check(unknown.strip.maxY == 800 - 60, "and the strip stops 60 points down")
    for bottom in [windowTopAX, windowTopAX - 5, 0] {
        check(OverlayLayout.window(frame: window, visible: visible, toolbarBottom: bottom, mainHeight: laptop.height, width: 260) == unknown,
              "a bottom at or above the window's top (\(bottom)) counts as no bars")
    }
    // Any bar Safari does report is followed, however short: the floor is only for none (#35).
    let short = OverlayLayout.window(frame: window, visible: visible, toolbarBottom: windowTopAX + 10, mainHeight: laptop.height, width: 260)
    check(short.panel.maxY == 800 - 10 - 8 && short.strip.maxY == 800 - 10, "a 10-point bar: 8 below it: \(short.panel)")
}

do {
    // The strip follows the window when it moves or changes size, and goes to whichever window it's given.
    let moved = window.offsetBy(dx: 150, dy: 40)
    let before = OverlayLayout.window(frame: window, visible: visible, toolbarBottom: windowTopAX + 52, mainHeight: laptop.height, width: 260)
    let after = OverlayLayout.window(frame: moved, visible: visible, toolbarBottom: windowTopAX - 40 + 52, mainHeight: laptop.height, width: 260)
    check(after.strip.minX == before.strip.minX + 150 && after.strip.maxX == before.strip.maxX + 150, "the strip moves with the window")
    check(after.panel == before.panel.offsetBy(dx: 150, dy: 40), "and so does the panel: \(before.panel) → \(after.panel)")
    let narrower = CGRect(x: 500, y: 100, width: 800, height: 700)
    let resized = OverlayLayout.window(frame: narrower, visible: visible, toolbarBottom: windowTopAX + 52, mainHeight: laptop.height, width: 260)
    check(resized.strip.minX == 496 && resized.panel.minX == 508, "dragging the window's left edge in takes the strip and panel along")
}

do {
    // The window is at the screen's left edge, as it is once Safari has its room back: the pointer
    // stops on the strip, as it does in full screen.
    let flush = CGRect(x: 0, y: 70, width: 1512, height: 879)
    let layout = OverlayLayout.window(frame: flush, visible: visible, toolbarBottom: 33 + 52, mainHeight: laptop.height, width: 260)
    check(layout.strip.contains(CGPoint(x: 0, y: 500)), "the pointer against the screen's left edge is on the strip")
    check(layout.panel == CGRect(x: 8, y: 78, width: 260, height: 949 - 52 - 8 - 78), "the panel is 8 points in: \(layout.panel)")
}

do {
    // Pushed partly off the left of the screen, the window's edge can't be reached; the screen's
    // edge, over the window, can. The panel shows on the screen too.
    let offLeft = CGRect(x: -300, y: 100, width: 1000, height: 700)
    let layout = OverlayLayout.window(frame: offLeft, visible: visible, toolbarBottom: windowTopAX + 52, mainHeight: laptop.height, width: 260)
    check(layout.strip.contains(CGPoint(x: 0, y: 400)), "the strip is at the screen's edge")
    check(layout.panel.minX == 8, "and the panel starts on the screen: \(layout.panel)")
    check(layout.panel.maxY == 748 - 8, "still below the window's toolbar")
}

do {
    // With the Dock on the left (visible frame from x 64), a window reaching under it.
    let dockLeft = CGRect(x: 64, y: 0, width: 1448, height: 949)
    let underDock = CGRect(x: 0, y: 100, width: 1000, height: 700)
    let layout = OverlayLayout.window(frame: underDock, visible: dockLeft, toolbarBottom: windowTopAX + 52, mainHeight: laptop.height, width: 260)
    check(layout.strip.minX == 60 && layout.strip.maxX == 68, "the strip is at the Dock's edge")
    check(layout.panel.minX == 72, "and the panel beside the Dock")
}

do {
    // A window on a second display, to the right and lower than the laptop.
    let external = CGRect(x: 1512, y: -200, width: 1920, height: 1055)
    let there = CGRect(x: 1700, y: -100, width: 1200, height: 900)
    let topAX = laptop.height - there.maxY
    let layout = OverlayLayout.window(frame: there, visible: external, toolbarBottom: topAX + 52, mainHeight: laptop.height, width: 300)
    check(layout.panel == CGRect(x: 1708, y: -92, width: 300, height: 900 - 52 - 16), "the panel is on that display, in the window: \(layout.panel)")
    check(layout.strip.contains(CGPoint(x: 1700, y: 0)), "and so is the strip")
}

do {
    // Just after the pointer brings the sidebar out it is still on the strip, so the strip has to
    // be close enough to the panel to keep it out; otherwise it would flicker in and out.
    let frames = [window, CGRect(x: 0, y: 70, width: 1512, height: 879), CGRect(x: -300, y: 100, width: 1000, height: 700)]
    for frame in frames {
        for width: CGFloat in [180, 420] {
            let topAX = laptop.height - frame.maxY
            let layout = OverlayLayout.window(frame: frame, visible: visible, toolbarBottom: topAX + 52, mainHeight: laptop.height, width: width)
            let kept = layout.panel.insetBy(dx: -OverlayReveal.margin, dy: -OverlayReveal.margin)
            let corners = [
                CGPoint(x: layout.strip.minX, y: layout.strip.minY), CGPoint(x: layout.strip.maxX, y: layout.strip.minY),
                CGPoint(x: layout.strip.minX, y: layout.strip.maxY), CGPoint(x: layout.strip.maxX, y: layout.strip.maxY),
            ]
            check(corners.allSatisfy(kept.contains), "window \(frame), width \(width): all of the strip keeps the sidebar out")
        }
    }
}

// MARK: - Safari's bars (#35)

// Which of a window's elements are bars Safari shows above the page (SafariBars.swift), against trees
// in trees/. All of them are made up (constructed-*), from what the live test of #26 measured on
// Safari 27.2 in a window at y 39: the compact toolbar at y 39–91, and the Favourites bar, when shown,
// a direct child of the window (an AXGroup with identifier FavoritesBarView) at y 91–119. The separate
// tab layout follows Tests/TabBarFinderChecks/trees/constructed-separate.json (its tab bar inside the
// split group), the full-screen toolbar inside a group, as compact-fullscreen.json recorded. Where the
// find bar goes isn't known; it's tried as a direct child of the window and inside the split group.
// Frames are [x, y, width, height] in Accessibility coordinates.

/// Which elements the search read the children of, as `role#identifier`. Each read costs a round
/// trip to Safari, every second while the sidebar can slide out.
nonisolated(unsafe) var barReads: [String] = []

struct BarTreeNode: Decodable, SafariBarNode {
    var role: String?
    var identifier: String?
    /// Kept to show it plays no part: Safari translates it.
    var descriptionText: String?
    var frame: CGRect?
    var kids: [BarTreeNode]

    enum CodingKeys: String, CodingKey {
        case role, identifier, frame
        case descriptionText = "description"
        case kids = "children"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decodeIfPresent(String.self, forKey: .role)
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
        descriptionText = try values.decodeIfPresent(String.self, forKey: .descriptionText)
        frame = try values.decodeIfPresent([CGFloat].self, forKey: .frame).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        kids = try values.decodeIfPresent([BarTreeNode].self, forKey: .kids) ?? []
    }

    func children() -> [BarTreeNode] {
        barReads.append("\(role ?? "?")#\(identifier ?? "")")
        return kids
    }

    /// This node and everything under it, with `change` made to each.
    func edited(_ change: (inout BarTreeNode) -> Void) -> BarTreeNode {
        var node = self
        change(&node)
        node.kids = node.kids.map { $0.edited(change) }
        return node
    }
}

let overlayChecksFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func barTree(_ name: String, in folder: URL = overlayChecksFolder.appending(path: "trees")) -> BarTreeNode {
    do {
        return try JSONDecoder().decode(BarTreeNode.self, from: Data(contentsOf: folder.appending(path: "\(name).json")))
    } catch {
        print("FAIL: can't read tree \(name): \(error)")
        exit(1)
    }
}

/// The bars in a window's tree, the way SafariWindowReader looks for them.
func bars(in window: BarTreeNode) -> [SafariBar] {
    SafariBars.bars(among: window.kids, windowFrame: window.frame!)
}

func barsBottom(_ window: BarTreeNode) -> CGFloat? {
    SafariBars.bottom(of: bars(in: window))
}

/// What SafariWindowReader logs about a window's bars.
func logged(_ window: BarTreeNode) -> String {
    SafariBars.summary(bars(in: window), windowTop: window.frame!.minY)
}

func describe(_ value: CGFloat?) -> String {
    value.map { "\($0)" } ?? "none"
}

/// How SafariWindowReader found the toolbar before #35, transcribed: the window's direct children with
/// role AXToolbar or AXTabGroup, under 200 points tall and starting in its top 200.
func previousToolbarBottom(_ window: BarTreeNode) -> CGFloat? {
    var bottom: CGFloat?
    for child in window.kids where child.role == "AXToolbar" || child.role == "AXTabGroup" {
        guard let frame = child.frame, frame.height < 200, frame.minY < window.frame!.minY + 200 else { continue }
        bottom = max(bottom ?? frame.maxY, frame.maxY)
    }
    return bottom
}

let compactTree = barTree("constructed-bars-compact")
let favouritesTree = barTree("constructed-bars-favourites")
let separateTree = barTree("constructed-bars-separate")
let separateFavouritesTree = barTree("constructed-bars-separate-favourites")
let separateDirectTree = barTree("constructed-bars-separate-direct")
let findTree = barTree("constructed-bars-find")
let fullScreenTree = barTree("constructed-bars-fullscreen")
let fullScreenFavouritesTree = barTree("constructed-bars-fullscreen-favourites")
let noBarsTree = barTree("constructed-bars-none")

do {
    // Each bar on its own, and stacked.
    let expected: [(String, BarTreeNode, CGFloat?)] = [
        ("the compact toolbar", compactTree, 91),
        ("the Favourites bar under it", favouritesTree, 119),
        ("the separate tab bar, inside the split group", separateTree, 127),
        ("the Favourites bar and the separate tab bar", separateFavouritesTree, 155),
        ("the separate tab bar as a direct child of the window", separateDirectTree, 155),
        ("the find bar under the Favourites bar", findTree, 155),
        ("the full-screen toolbar, in its group", fullScreenTree, 52),
        ("the full-screen toolbar with the Favourites bar", fullScreenFavouritesTree, 80),
        ("no bars at all", noBarsTree, nil),
    ]
    for (what, tree, bottom) in expected {
        check(barsBottom(tree) == bottom, "\(what): the bars end at \(describe(bottom)), found \(describe(barsBottom(tree))) (\(logged(tree)))")
    }
}

do {
    // What counted, and how the log says it.
    check(bars(in: compactTree).map(\.role) == ["AXToolbar"], "the compact window's only bar is its toolbar, not its buttons or the page")
    check(bars(in: favouritesTree).map(\.identifier) == [nil, "FavoritesBarView"], "then the Favourites bar")
    // The log measures from the window's top, so a window that moves doesn't log again.
    check(logged(favouritesTree) == "AXToolbar 0–52, AXGroup FavoritesBarView 52–80", "the log line: \(logged(favouritesTree))")
    check(logged(separateTree) == "AXToolbar 0–52, AXGroup 52–88", "the separate tab bar's group: \(logged(separateTree))")
    check(logged(separateDirectTree).hasSuffix("AXOpaqueProviderGroup TabBar 80–116"), "an identifier is cut at its ?: \(logged(separateDirectTree))")
    check(logged(fullScreenTree) == "AXGroup 0–52", "the full-screen toolbar's group: \(logged(fullScreenTree))")
    let movedWindow = favouritesTree.edited { $0.frame = $0.frame?.offsetBy(dx: 300, dy: 120) }
    check(logged(movedWindow) == logged(favouritesTree), "moving the window changes nothing in it: \(logged(movedWindow))")
    check(SafariBars.summary([], windowTop: 39) == "none", "and none says so")
}

do {
    // Only the split group's children are read: never the toolbar's, a bar's, or the page's.
    for (name, tree) in [("compact", compactTree), ("favourites", favouritesTree), ("separate", separateTree), ("find", findTree),
                         ("full screen", fullScreenTree), ("full screen with favourites", fullScreenFavouritesTree), ("none", noBarsTree)] {
        barReads = []
        _ = bars(in: tree)
        check(barReads == ["AXSplitGroup#"], "\(name): only the split group's children are read: \(barReads)")
    }
    // The same on the windows #20 recorded in Safari 26, which have no frames: nothing counts, and
    // the reads stay the same.
    let recorded = overlayChecksFolder.deletingLastPathComponent().appending(path: "TabBarFinderChecks/trees")
    for name in ["compact-window", "compact-fullscreen"] {
        barReads = []
        let tree = barTree(name, in: recorded)
        check(SafariBars.bars(among: tree.kids, windowFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)).isEmpty, "\(name) without frames: no bars")
        check(barReads == ["AXSplitGroup#"], "\(name): only the split group's children are read: \(barReads)")
    }
}

do {
    // The Favourites bar is found by its identifier. Its description is translated and plays no part,
    // and its identifier counts even with a gap above it, where an unnamed bar wouldn't.
    let german = favouritesTree.edited { if $0.identifier == "FavoritesBarView" { $0.descriptionText = "Favoritenleiste" } }
    check(barsBottom(german) == 119, "a translated description changes nothing")
    let gapped = favouritesTree.edited { if $0.identifier == "FavoritesBarView" { $0.frame = CGRect(x: 100, y: 101, width: 1200, height: 28) } }
    check(barsBottom(gapped) == 129, "the Favourites bar 10 points below the toolbar still counts: \(describe(barsBottom(gapped)))")
    let unnamed = gapped.edited { if $0.identifier == "FavoritesBarView" { $0.identifier = nil } }
    check(barsBottom(unnamed) == 91, "an unnamed bar 10 points below doesn't: \(describe(barsBottom(unnamed)))")
    let touching = favouritesTree.edited { if $0.identifier == "FavoritesBarView" { $0.identifier = nil; $0.frame = CGRect(x: 100, y: 94, width: 1200, height: 28) } }
    check(barsBottom(touching) == 122, "but one within 4 points of the bar above does: \(describe(barsBottom(touching)))")
}

do {
    // The separate tab bar counts by its identifier, or as the bar under the toolbar without one.
    let unnamed = separateTree.edited { if $0.identifier?.hasPrefix("TabBar?") == true { $0.identifier = nil } }
    check(barsBottom(unnamed) == 127, "the tab bar's group counts by where it is, not its identifier")
    let directUnnamed = separateDirectTree.edited { if $0.identifier?.hasPrefix("TabBar?") == true { $0.identifier = nil; $0.role = "AXGroup" } }
    check(barsBottom(directUnnamed) == 155, "so does an unnamed group under the Favourites bar")
    // The page beside it never counts, even in a window too short for it to look tall.
    let tiny = separateTree.edited { node in
        if node.role == "AXTabGroup" { node.frame = CGRect(x: 100, y: 127, width: 1200, height: 120) }
    }
    check(barsBottom(tiny) == 127, "the page in a short window isn't a bar: \(describe(barsBottom(tiny)))")
}

do {
    // The find bar: nothing names it, so it counts by sitting under the other bars, as a direct child
    // of the window or inside the split group, above the page.
    let underToolbar = findTree.edited { node in
        if node.identifier == "FavoritesBarView" { node.frame = nil }
        if node.descriptionText == "find banner" { node.frame = CGRect(x: 100, y: 91, width: 1200, height: 36) }
    }
    check(barsBottom(underToolbar) == 127, "the find bar right under the toolbar: \(describe(barsBottom(underToolbar)))")
    var inSplit = compactTree
    inSplit.kids[0].kids.insert(barTree("constructed-bars-find").kids[3].edited { $0.frame = $0.frame.map { CGRect(x: $0.minX, y: 91, width: $0.width, height: $0.height) } }, at: 1)
    check(barsBottom(inSplit) == 127, "the find bar inside the split group, above the page: \(describe(barsBottom(inSplit)))")
    // Something lower down that isn't stacked under the bars isn't one of them.
    let lower = findTree.edited { if $0.descriptionText == "find banner" { $0.frame = CGRect(x: 100, y: 180, width: 1200, height: 36) } }
    check(barsBottom(lower) == 119, "a group further down the window doesn't count: \(describe(barsBottom(lower)))")
}

do {
    // Never the window's buttons, a sheet or anything tall or narrow.
    var withSheet = compactTree
    withSheet.kids.append(barTree("constructed-bars-compact").kids[1].edited { $0.role = "AXSheet"; $0.frame = CGRect(x: 400, y: 91, width: 600, height: 150) })
    check(barsBottom(withSheet) == 91, "a sheet under the toolbar isn't a bar: \(describe(barsBottom(withSheet)))")
    let tallButtons = compactTree.edited { if $0.role == "AXButton" { $0.frame = CGRect(x: 112, y: 39, width: 200, height: 120) } }
    check(barsBottom(tallButtons) == 91, "nor are the window's buttons, whatever their size")
    let narrow = favouritesTree.edited { if $0.identifier == "FavoritesBarView" { $0.frame = CGRect(x: 100, y: 91, width: 20, height: 28) } }
    check(barsBottom(narrow) == 91, "nor something taller than it is wide")
    let tall = favouritesTree.edited { if $0.identifier == "FavoritesBarView" { $0.frame = CGRect(x: 100, y: 91, width: 1200, height: 250) } }
    check(barsBottom(tall) == 91, "nor something 200 points tall or more")
}

do {
    // Full screen: the toolbar slides down from the top. Slid away, or on its way, it isn't shown, and
    // Safari reports no bars, so the overlay keeps to its floor.
    func movingToolbar(to y: CGFloat) -> BarTreeNode {
        var tree = fullScreenFavouritesTree
        tree.kids[1] = tree.kids[1].edited { $0.frame = $0.frame?.offsetBy(dx: 0, dy: y) }
        return tree
    }
    check(barsBottom(movingToolbar(to: -80)) == nil, "slid out of sight above the screen: no bars")
    check(barsBottom(movingToolbar(to: -30)) == nil, "partly slid down: still none")
    check(barsBottom(movingToolbar(to: 0)) == 80, "all the way down: the toolbar and the Favourites bar")
    // On a display with a notch, the toolbar may come down below the menu bar rather than at the top.
    check(barsBottom(movingToolbar(to: 37)) == 117, "below a menu bar: \(describe(barsBottom(movingToolbar(to: 37))))")
    // A toolbar Safari reports far down the window isn't its toolbar.
    let farDown = compactTree.edited { if $0.role == "AXToolbar" { $0.frame = CGRect(x: 100, y: 300, width: 1200, height: 52) } }
    check(barsBottom(farDown) == nil, "a toolbar more than 200 points down doesn't count")
}

do {
    // Before #35 only the toolbar counted, and in full screen nothing did: these are the cases the
    // live test found, and the ones the issue adds.
    check(previousToolbarBottom(compactTree) == 91 && barsBottom(compactTree) == 91, "the compact toolbar was found before, and still is")
    check(previousToolbarBottom(favouritesTree) == 91, "the Favourites bar was missed, so the sidebar covered it")
    check(previousToolbarBottom(separateTree) == 91 && previousToolbarBottom(findTree) == 91, "so were the separate tab bar and the find bar")
    check(previousToolbarBottom(fullScreenTree) == nil, "and the full-screen toolbar, in its group")
}

do {
    // The whole way, with the live test's window at y 39 (AppKit y 143 to 943): the panel starts 8
    // points below the lowest bar, and the strip stops at it. Before, it started at y 107 every time.
    let liveWindow = CGRect(x: 100, y: laptop.height - 39 - 800, width: 1200, height: 800)
    func tops(_ tree: BarTreeNode) -> (panel: CGFloat, strip: CGFloat) {
        let layout = OverlayLayout.window(frame: liveWindow, visible: visible, toolbarBottom: barsBottom(tree), mainHeight: laptop.height, width: 260)
        return (laptop.height - layout.panel.maxY, laptop.height - layout.strip.maxY)
    }
    let cases: [(String, BarTreeNode, CGFloat)] = [
        ("compact toolbar", compactTree, 91), ("Favourites bar", favouritesTree, 119), ("separate tab bar", separateTree, 127),
        ("Favourites and separate tab bars", separateFavouritesTree, 155), ("find bar", findTree, 155),
    ]
    for (what, tree, bottom) in cases {
        let (panel, strip) = tops(tree)
        check(panel == bottom + 8, "\(what): the panel starts at y \(bottom + 8), 8 below the bars: y \(panel)")
        check(strip == bottom, "\(what): the strip stops at y \(bottom): y \(strip)")
    }
    let (panel, strip) = tops(noBarsTree)
    check(panel == 39 + 60 + 8 && strip == 39 + 60, "no bars: the floor, 60 points down and 8 more: y \(panel), strip y \(strip)")

    // Full screen on the laptop, the same way.
    func fullScreenTop(_ bottom: CGFloat?) -> (panel: CGFloat, strip: CGFloat) {
        let layout = OverlayLayout.fullScreen(screen: laptop, toolbarBottom: bottom, mainHeight: laptop.height, width: 260)
        return (laptop.height - layout.panel.maxY, laptop.height - layout.strip.maxY)
    }
    check(fullScreenTop(barsBottom(fullScreenTree)) == (60, 52), "full screen: 8 below the toolbar: \(fullScreenTop(barsBottom(fullScreenTree)))")
    check(fullScreenTop(barsBottom(fullScreenFavouritesTree)) == (88, 80), "full screen with the Favourites bar: below it: \(fullScreenTop(barsBottom(fullScreenFavouritesTree)))")
    check(fullScreenTop(nil) == (68, 60), "full screen with the toolbar slid away: the floor, as before")
}

// MARK: - Coming out and going away

let layout = OverlayLayout.window(frame: window, visible: visible, toolbarBottom: windowTopAX + 52, mainHeight: laptop.height, width: 260)
let onStrip = CGPoint(x: 300, y: 400)
let overPanel = CGPoint(x: 400, y: 400)
let nearPanel = CGPoint(x: layout.panel.maxX + 20, y: 400)
let overPage = CGPoint(x: 900, y: 400)

func poll(_ reveal: inout OverlayReveal, _ pointer: CGPoint, front: Bool = true, holding: Bool = false, mayReveal: () -> Bool = { true }) -> OverlayReveal.Action {
    reveal.poll(pointer: pointer, strip: layout.strip, panel: layout.panel, safariInFront: front, holding: holding, mayReveal: mayReveal)
}

do {
    var reveal = OverlayReveal()
    check(poll(&reveal, overPage) == .none && !reveal.isRevealed, "hidden while the pointer is over the page")
    check(poll(&reveal, overPanel) == .none, "even where the panel would be")
    check(poll(&reveal, onStrip) == .reveal && reveal.isRevealed, "the pointer on the strip brings it out")
    check(!reveal.isPinned, "by the pointer, not the shortcut")
    check(poll(&reveal, onStrip) == .none, "it stays out while the pointer is still there")
    check(poll(&reveal, overPanel) == .none, "and while it's over the sidebar")
    check(poll(&reveal, nearPanel) == .none, "and a little way off it")
    check(poll(&reveal, overPage) == .conceal && !reveal.isRevealed, "it goes away when the pointer leaves it")
    check(poll(&reveal, overPage) == .none, "once")
}

do {
    // Only over Safari.
    var reveal = OverlayReveal()
    check(poll(&reveal, onStrip, front: false) == .none, "with another app in front, the strip does nothing")
    _ = poll(&reveal, onStrip)
    check(poll(&reveal, overPanel, front: false) == .conceal, "and if another app comes forward while it's out, it goes away")
    _ = poll(&reveal, onStrip)
    check(poll(&reveal, overPanel, front: false, holding: true) == .conceal, "even in the middle of a drag or rename")
}

do {
    // Checks too slow for every poll are only made on the strip, and can keep it hidden.
    var reveal = OverlayReveal()
    var asked = 0
    _ = poll(&reveal, overPage) { asked += 1; return true }
    _ = poll(&reveal, overPanel) { asked += 1; return true }
    check(asked == 0, "the slow checks aren't made while the pointer is away from the strip")
    check(poll(&reveal, onStrip) { asked += 1; return false } == .none && !reveal.isRevealed, "on another Space, the strip does nothing")
    check(asked == 1, "the check was made once, on the strip")
    _ = poll(&reveal, onStrip) { asked += 1; return true }
    _ = poll(&reveal, overPage) { asked += 1; return true }
    check(asked == 2, "and not again while the sidebar is out")
}

do {
    // A rename, context menu or drag keeps it out wherever the pointer goes.
    var reveal = OverlayReveal()
    _ = poll(&reveal, onStrip)
    check(poll(&reveal, overPage, holding: true) == .none && reveal.isRevealed, "held out while the pointer is away")
    check(poll(&reveal, overPage) == .conceal, "and goes away once nothing holds it")
}

do {
    // The toolbar button or its shortcut.
    var reveal = OverlayReveal()
    check(reveal.toggle() == .reveal && reveal.isRevealed && reveal.isPinned, "the shortcut brings it out")
    check(poll(&reveal, overPage) == .none, "and it stays while the pointer hasn't been over it yet")
    check(poll(&reveal, overPanel) == .none, "nor while it's over it")
    check(poll(&reveal, overPage) == .conceal && !reveal.isPinned, "then goes away once the pointer leaves it")

    check(reveal.toggle() == .reveal, "out again with the shortcut")
    check(reveal.toggle() == .conceal && !reveal.isRevealed && !reveal.isPinned, "and the shortcut again puts it away")

    _ = poll(&reveal, onStrip)
    check(reveal.toggle() == .conceal, "the shortcut also puts away a sidebar the pointer brought out")
    check(poll(&reveal, overPage) == .none, "and it stays away")
}

do {
    // A visit before the shortcut doesn't count for after it.
    var reveal = OverlayReveal()
    _ = poll(&reveal, onStrip)
    _ = poll(&reveal, overPanel)
    _ = poll(&reveal, overPage)
    _ = reveal.toggle()
    check(poll(&reveal, overPage) == .none && reveal.isRevealed, "brought out with the shortcut, it waits for a new visit")
}

if failures == 0 {
    print("sidebar overlay checks passed")
} else {
    print("\(failures) sidebar overlay check(s) failed")
    exit(1)
}
