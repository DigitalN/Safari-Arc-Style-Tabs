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

// MARK: - Full-screen layout, unchanged

// The layout DockController.layOutOverlay worked out before the setting existed, transcribed.
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
    for toolbar: CGFloat? in [nil, screenTop + 20, screenTop + 52, screenTop + 97.5, screenTop + 900] {
        for width: CGFloat in [180, 260, 333, 420] {
            let layout = OverlayLayout.fullScreen(screen: screen, toolbarBottom: toolbar, mainHeight: laptop.height, width: width)
            let old = oldFullScreenPanel(screen: screen, toolbarBottom: toolbar, mainHeight: laptop.height, width: width)
            check(layout.panel == old, "full screen \(screen), toolbar \(toolbar.map { "\($0)" } ?? "unknown"), width \(width): the panel is where it was (\(layout.panel) vs \(old))")
        }
    }
}

do {
    // The strip is the screen's left edge, as before: within 2 points of it, the screen's height.
    let strip = OverlayLayout.fullScreen(screen: laptop, toolbarBottom: nil, mainHeight: laptop.height, width: 260).strip
    check(strip.contains(CGPoint(x: 0, y: 500)), "the pointer against the screen's left edge brings it out")
    check(strip.contains(CGPoint(x: 2, y: 500)), "so does 2 points in")
    check(!strip.contains(CGPoint(x: 2.5, y: 500)), "but not more")
    check(strip.contains(CGPoint(x: 0, y: 0)) && strip.contains(CGPoint(x: 0, y: 982)), "from the bottom of the screen to the top")
    check(!strip.contains(CGPoint(x: 0, y: 983)) && !strip.contains(CGPoint(x: 0, y: -1)), "and no further")
}

// MARK: - A window's layout

// Laptop screen, menu bar 33 pt (visible frame up to 949), Dock at the bottom (from 70).
let visible = CGRect(x: 0, y: 70, width: 1512, height: 879)
// A window from x 300 to 1300, y 100 to 800 (AppKit); its top is 182 down from the top in AX terms.
let window = CGRect(x: 300, y: 100, width: 1000, height: 700)
let windowTopAX = laptop.height - window.maxY

do {
    // A 52-point toolbar: shorter than the 60 points full screen keeps clear, which win, as there.
    let layout = OverlayLayout.window(frame: window, visible: visible, toolbarBottom: windowTopAX + 52, mainHeight: laptop.height, width: 260)
    // Kept clear down to AppKit y 740; the panel is 8 pt in from the window's left and bottom and from that.
    check(layout.panel == CGRect(x: 308, y: 108, width: 260, height: 624), "the panel is over the page, below the toolbar: \(layout.panel)")
    check(layout.strip == RevealStrip(minX: 296, maxX: 304, minY: 100, maxY: 740), "the strip is the window's left edge beside the page: \(layout.strip)")
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
    // Safari didn't say where its toolbar ends, or gave a value inside the title bar.
    let unknown = OverlayLayout.window(frame: window, visible: visible, toolbarBottom: nil, mainHeight: laptop.height, width: 260)
    let tooHigh = OverlayLayout.window(frame: window, visible: visible, toolbarBottom: windowTopAX + 10, mainHeight: laptop.height, width: 260)
    check(unknown.panel.maxY == 800 - 60 - 8, "without the toolbar's bottom, the panel starts 60 points down the window")
    check(tooHigh == unknown, "and never higher than that")
}

do {
    // The strip follows the window when it moves or changes size, and goes to whichever window it's given.
    let moved = window.offsetBy(dx: 150, dy: 40)
    let before = OverlayLayout.window(frame: window, visible: visible, toolbarBottom: windowTopAX + 52, mainHeight: laptop.height, width: 260)
    let after = OverlayLayout.window(frame: moved, visible: visible, toolbarBottom: windowTopAX - 40 + 52, mainHeight: laptop.height, width: 260)
    check(after.strip.minX == before.strip.minX! + 150 && after.strip.maxX == before.strip.maxX + 150, "the strip moves with the window")
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
    check(layout.panel == CGRect(x: 8, y: 78, width: 260, height: 949 - 60 - 8 - 78), "the panel is 8 points in: \(layout.panel)")
}

do {
    // Pushed partly off the left of the screen, the window's edge can't be reached; the screen's
    // edge, over the window, can. The panel shows on the screen too.
    let offLeft = CGRect(x: -300, y: 100, width: 1000, height: 700)
    let layout = OverlayLayout.window(frame: offLeft, visible: visible, toolbarBottom: windowTopAX + 52, mainHeight: laptop.height, width: 260)
    check(layout.strip.contains(CGPoint(x: 0, y: 400)), "the strip is at the screen's edge")
    check(layout.panel.minX == 8, "and the panel starts on the screen: \(layout.panel)")
    check(layout.panel.maxY == 740 - 8, "still below the window's toolbar")
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
    check(layout.panel == CGRect(x: 1708, y: -92, width: 300, height: 900 - 60 - 16), "the panel is on that display, in the window: \(layout.panel)")
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
                CGPoint(x: layout.strip.minX!, y: layout.strip.minY), CGPoint(x: layout.strip.maxX, y: layout.strip.minY),
                CGPoint(x: layout.strip.minX!, y: layout.strip.maxY), CGPoint(x: layout.strip.maxX, y: layout.strip.maxY),
            ]
            check(corners.allSatisfy(kept.contains), "window \(frame), width \(width): all of the strip keeps the sidebar out")
        }
    }
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
