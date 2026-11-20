import CoreGraphics
import Foundation

// Checks for keeping the docked sidebar beside Safari's window without redoing work on every move
// (DockedPanelRules.swift, #85): when the panel's shadow is worked out again, when ordering it behind
// Safari's window again can be skipped, and that a drag of Safari's window checks the order only once it
// settles. What the window server does with them needs the running app.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

// MARK: - The shadow

do {
    let docked = PanelShadowShape(size: CGSize(width: 288, height: 900), attached: true, scale: 2)
    check(DockedPanelRules.needsNewShadow(docked, last: nil), "the first time the panel is placed")
    check(!DockedPanelRules.needsNewShadow(docked, last: docked), "not when only its position changed: a move while Safari's window is dragged")

    var taller = docked
    taller.size.height = 901
    check(DockedPanelRules.needsNewShadow(taller, last: docked), "when Safari's window gets taller")
    var wider = docked
    wider.size.width = 320
    check(DockedPanelRules.needsNewShadow(wider, last: docked), "when the sidebar gets wider")

    var floating = docked
    floating.attached = false
    check(DockedPanelRules.needsNewShadow(floating, last: docked), "when it goes from attached to floating, at the same size: the corner fills go")
    check(DockedPanelRules.needsNewShadow(docked, last: floating), "and back")

    var otherDisplay = docked
    otherDisplay.scale = 1
    check(DockedPanelRules.needsNewShadow(otherDisplay, last: docked), "when it moves to a display with another scale")
}

// MARK: - Ordering behind Safari's window

do {
    let safari = 410, panel = 77, mail = 520, finder = 9, menuBar = 3
    check(DockedPanelRules.isDirectlyBehind(panel: panel, window: safari, frontToBack: [menuBar, safari, panel, mail, finder]),
          "directly behind Safari's window: nothing to do")
    check(DockedPanelRules.isDirectlyBehind(panel: panel, window: safari, frontToBack: [menuBar, mail, safari, panel]),
          "with another app's window in front of both, and the panel at the back")
    check(!DockedPanelRules.isDirectlyBehind(panel: panel, window: safari, frontToBack: [menuBar, safari, mail, panel, finder]),
          "another app's window between them: ordered again")
    check(!DockedPanelRules.isDirectlyBehind(panel: panel, window: safari, frontToBack: [menuBar, panel, safari, mail]),
          "in front of Safari's window (a click on it brings it forward): ordered again")
    check(!DockedPanelRules.isDirectlyBehind(panel: panel, window: safari, frontToBack: [menuBar, safari, 411, panel]),
          "another of Safari's windows between them: ordered again")
    check(!DockedPanelRules.isDirectlyBehind(panel: panel, window: safari, frontToBack: [menuBar, safari, mail]),
          "the panel not on screen")
    check(!DockedPanelRules.isDirectlyBehind(panel: panel, window: safari, frontToBack: [menuBar, panel, mail]),
          "Safari's window not on screen")
    check(!DockedPanelRules.isDirectlyBehind(panel: panel, window: safari, frontToBack: [menuBar, safari]),
          "Safari's window at the back")
    check(!DockedPanelRules.isDirectlyBehind(panel: panel, window: safari, frontToBack: []),
          "no list from the window server")
}

// MARK: - While Safari's window is dragged

do {
    var rule = PanelOrderingRule()
    check(rule.layout(panelVisible: true, dragging: false) == .check, "a layout that isn't a drag checks the windows' order")
    check(rule.settled() == .skip, "and a move that settles without a drag doesn't check again")

    // A drag: many moves with the button held, then the mouse-up.
    var drag = rule
    for _ in 0..<50 {
        check(drag.layout(panelVisible: true, dragging: true) == .skip, "a move during a drag neither checks nor re-orders")
    }
    check(drag.settled() == .check, "the drag settling checks the order once")
    check(drag.settled() == .skip, "and only once")

    // Something else lays the sidebar out during the drag: Safari activated, its window focused.
    var interrupted = PanelOrderingRule()
    _ = interrupted.layout(panelVisible: true, dragging: true)
    check(interrupted.layout(panelVisible: true, dragging: false) == .check, "a focus change during a drag still checks")
    check(interrupted.settled() == .skip, "and then the drag's end has nothing left to check")
    _ = interrupted.layout(panelVisible: true, dragging: true)
    check(interrupted.settled() == .check, "unless the drag moved Safari's window again after it")

    // The panel isn't on screen: shown again, or ordered out to come to the Space being shown.
    var hidden = PanelOrderingRule()
    check(hidden.layout(panelVisible: false, dragging: false) == .order, "a panel that isn't on screen is ordered in")
    check(hidden.layout(panelVisible: false, dragging: true) == .order, "even during a drag")
    check(hidden.settled() == .skip, "after which the drag's end has nothing to check")
}

// What a settled check does with the windows' order: re-orders only when something is between them.
do {
    let safari = 410, panel = 77, mail = 520
    var rule = PanelOrderingRule()
    _ = rule.layout(panelVisible: true, dragging: true)
    let afterDrag = rule.settled()
    func reorders(_ frontToBack: [Int]) -> Bool {
        afterDrag == .order || afterDrag == .check && !DockedPanelRules.isDirectlyBehind(panel: panel, window: safari, frontToBack: frontToBack)
    }
    check(!reorders([safari, panel, mail]), "after a drag, a panel still directly behind isn't ordered again")
    check(reorders([safari, mail, panel]), "a window that came between them during the drag puts it back")
}

if failures == 0 {
    print("docked panel checks passed")
} else {
    print("\(failures) docked panel check(s) failed")
    exit(1)
}
