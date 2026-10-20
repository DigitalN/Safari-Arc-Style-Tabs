import Foundation
import CoreGraphics

@main struct AutoHideTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("FAILED: \(message)") }
    }
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let window = CGRect(x: 200, y: 100, width: 1000, height: 700)
        let layout = SidebarOverlayLayout.make(window: window, screen: screen, toolbarBottom: 720, width: 260, fullScreen: false)!
        expect(window.contains(layout.frame) && layout.frame.width == 260, "regular overlay stays inside Safari")
        expect(layout.frame.maxY == 712 && layout.frame.minY == 108, "overlay clears toolbar and bottom window edge")
        expect(layout.trigger.contains(CGPoint(x: 201, y: 300)), "Safari's left content edge reveals the sidebar")
        expect(!layout.trigger.contains(CGPoint(x: 1, y: 300)) && !layout.trigger.contains(CGPoint(x: 201, y: 760)), "screen edge and toolbar do not reveal an inset regular window")
        let otherScreen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let otherWindow = CGRect(x: -1800, y: -100, width: 1200, height: 700)
        let other = SidebarOverlayLayout.make(window: otherWindow, screen: otherScreen, toolbarBottom: 515, width: 420, fullScreen: false)!
        expect(other.frame.minX == -1792 && other.frame.maxY == 507 && otherScreen.contains(other.frame), "offset and negative-coordinate displays use the correct window edge")
        let clipped = SidebarOverlayLayout.make(window: CGRect(x: -100, y: 100, width: 700, height: 700), screen: screen, toolbarBottom: nil, width: 260, fullScreen: false)!
        expect(clipped.frame.minX == 8 && clipped.trigger.minX == 0 && screen.contains(clipped.frame), "partly offscreen Safari remains accessible at the visible edge")
        let full = SidebarOverlayLayout.make(window: screen, screen: screen, toolbarBottom: 870, width: 260, fullScreen: true)!
        expect(full.trigger.contains(CGPoint(x: 1, y: 940)) && full.frame.maxY == 862, "fullscreen keeps screen-edge reveal and clears Safari's toolbar")
        let narrow = SidebarOverlayLayout.make(window: CGRect(x: 100, y: 100, width: 200, height: 400), screen: screen, toolbarBottom: nil, width: 420, fullScreen: false)!
        expect(narrow.frame.width == 184 && narrow.frame.maxX < 300, "drawer width is bounded by a narrow Safari window")
        expect(SidebarOverlayLayout.make(window: CGRect(x: 2000, y: 0, width: 500, height: 500), screen: screen, toolbarBottom: nil, width: 260, fullScreen: false) == nil, "offscreen windows cannot create an overlay")
        expect(SidebarOverlayLayout.make(window: CGRect(x: 0, y: 0, width: 500, height: 100), screen: screen, toolbarBottom: nil, width: 260, fullScreen: false) == nil, "tiny windows never overflow into browser chrome")

        var hover = SidebarAutoHide()
        expect(hover.update(now: 0, atEdge: false, inside: false, foreground: true, editing: false, tracking: false) == .none && !hover.revealed, "auto-hide begins collapsed")
        expect(hover.update(now: 0, atEdge: true, inside: false, foreground: true, editing: false, tracking: false) == .reveal && hover.revealed, "edge hover reveals")
        expect(hover.update(now: 0.1, atEdge: true, inside: false, foreground: true, editing: false, tracking: false) == .none, "pointer can cross from the trigger into the drawer")
        _ = hover.update(now: 0.2, atEdge: false, inside: true, foreground: true, editing: false, tracking: false)
        expect(hover.update(now: 1, atEdge: false, inside: false, foreground: true, editing: false, tracking: false) == .none, "moving away starts a grace period")
        expect(hover.update(now: 1.1, atEdge: false, inside: false, foreground: true, editing: false, tracking: false) == .none, "brief pointer departures do not flicker")
        expect(hover.update(now: 1.23, atEdge: false, inside: false, foreground: true, editing: false, tracking: false) == .conceal && !hover.revealed, "moving away collapses after the grace period")
        _ = hover.update(now: 2, atEdge: true, inside: false, foreground: true, editing: false, tracking: false)
        _ = hover.update(now: 2.1, atEdge: false, inside: false, foreground: true, editing: false, tracking: false)
        _ = hover.update(now: 2.2, atEdge: false, inside: true, foreground: true, editing: false, tracking: false)
        expect(hover.update(now: 2.4, atEdge: false, inside: false, foreground: true, editing: false, tracking: false) == .none && hover.revealed, "returning to the drawer resets the hide deadline")
        expect(hover.update(now: 3, atEdge: false, inside: false, foreground: true, editing: true, tracking: false) == .none && hover.revealed, "renaming or a space editor keeps the drawer open")
        expect(hover.update(now: 4, atEdge: false, inside: false, foreground: true, editing: false, tracking: true) == .none && hover.revealed, "dragging and menus keep the drawer open")
        _ = hover.update(now: 5, atEdge: false, inside: false, foreground: true, editing: false, tracking: false)
        expect(hover.update(now: 5.23, atEdge: false, inside: false, foreground: true, editing: false, tracking: false) == .conceal, "drawer hides after interaction finishes and pointer remains outside")
        expect(hover.toggle() == .reveal, "toolbar button opens collapsed drawer")
        expect(hover.update(now: 10, atEdge: false, inside: false, foreground: true, editing: false, tracking: false) == .none && hover.revealed, "explicit opening waits for the pointer to visit")
        _ = hover.update(now: 11, atEdge: false, inside: true, foreground: true, editing: false, tracking: false)
        _ = hover.update(now: 12, atEdge: false, inside: false, foreground: true, editing: false, tracking: false)
        expect(hover.update(now: 12.23, atEdge: false, inside: false, foreground: true, editing: false, tracking: false) == .conceal, "explicit opening returns to hover rules after a visit")
        _ = hover.toggle()
        expect(hover.update(now: 20, atEdge: true, inside: true, foreground: false, editing: true, tracking: true) == .conceal && !hover.revealed, "another app immediately dismisses even during editing or tracking")
        expect(hover.update(now: 21, atEdge: false, inside: false, foreground: true, editing: false, tracking: false) == .none && !hover.revealed, "returning to Safari does not resurrect a hidden drawer")
        _ = hover.toggle()
        expect(hover.toggle() == .conceal && !hover.revealed, "second toolbar action closes the drawer")
        _ = hover.toggle(); hover.reset()
        expect(!hover.revealed && hover.update(now: 30, atEdge: false, inside: false, foreground: true, editing: false, tracking: false) == .none, "mode/window changes clear prior hover and shortcut state")
        print("Passed \(checks) auto-hide geometry and interaction checks.")
    }
}
