import AppKit
import Observation
import SwiftUI

/// How the panel is drawn: attached to Safari's window, or floating over a full-screen window.
@Observable
final class PanelStyle {
    var attached = true
}

/// The borderless panel that holds the sidebar. It's non-activating, so clicking a tab
/// doesn't pull focus away from Safari.
///
/// When attached, the panel sits directly behind Safari's window and reaches
/// `cornerFill` points under it, so it can fill the notches left by Safari's rounded
/// corners; without that, whatever is behind the two windows shows through.
final class SidebarPanel: NSPanel {
    static let cornerRadius: CGFloat = 14
    /// At least as large as Safari's window corner radius.
    static let cornerFill: CGFloat = 28

    let style = PanelStyle()

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = false
        level = .normal
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]

        contentView = FirstMouseHostingView(rootView: PanelChrome(style: style) { rootView })
    }

    /// Called on left and middle mouse-down anywhere in the panel, before the click is
    /// handled. Right-clicks are left alone so context menus open without switching apps.
    /// A left click on the profile dropdown runs it once the menu closes (`finishMenuMouseDown`),
    /// and one on the Settings gear never does (`keepsSafariBehind()`).
    var onMouseDown: (() -> Void)?

    /// Called on a middle mouse-down with its position in the window's coordinates (origin at the
    /// top left, like SwiftUI's `.global`), after Safari has been brought forward. Says whether
    /// the click was used; if not, it is passed on.
    ///
    /// SwiftUI has no gesture for the middle button, and asking its views what is under the pointer
    /// gets an internal container, not the row (#21), so the panel finds the row itself.
    var onMiddleClick: ((CGPoint) -> Bool)?

    /// When the last left or middle mouse-down reached the panel, taken from the event itself
    /// so it doesn't include time spent before the event was handled.
    private(set) var lastMouseDown = Date.distantPast

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .otherMouseDown {
            lastMouseDown = Date(timeIntervalSinceNow: event.timestamp - ProcessInfo.processInfo.systemUptime)
            // A view that opens a menu on mouse-down (the profile dropdown, #39) runs this itself once the
            // menu has closed: Safari coming forward now would close the menu as it opens. The Settings gear
            // (#43) never runs it: it brings Side Tabs' own Settings window forward, and Safari would cover it.
            if !(event.type == .leftMouseDown && (opensMenu(at: event) || keepsSafariBehind(at: event))) {
                onMouseDown?()
            }
        }
        if event.type == .otherMouseDown, event.buttonNumber == 2, let onMiddleClick, let view = contentView {
            let local = view.convert(event.locationInWindow, from: nil)
            let point = CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
            if onMiddleClick(point) {
                return
            }
        }
        super.sendEvent(event)
    }

    /// Runs what a left mouse-down normally does first (`onMouseDown`: bringing Safari forward), for a
    /// view that opens a menu on mouse-down, once its menu has closed.
    func finishMenuMouseDown() {
        onMouseDown?()
    }

    /// Whether the click lands on a view that opens a menu on mouse-down. The hit can land on the view
    /// SwiftUI wraps an AppKit view in, so this also looks at the topmost views inside it under the click.
    private func opensMenu(at event: NSEvent) -> Bool {
        guard let contentView, let frameView = contentView.superview,
              var view = contentView.hitTest(frameView.convert(event.locationInWindow, from: nil)) else { return false }
        while !(view is OpensMenuOnMouseDown) {
            let point = view.convert(event.locationInWindow, from: nil)
            guard let inner = view.subviews.last(where: { !$0.isHidden && $0.frame.contains(point) }) else { return false }
            view = inner
        }
        return true
    }

    /// The areas `keepsSafariBehind()` marks, each added as it comes into the panel. Those areas take no
    /// clicks themselves, so hit-testing can't find them, and SwiftUI's order of the views it hosts says
    /// nothing about which is on top; so they say where they are instead. Weak, so a gone one drops out.
    fileprivate let safariStaysBehindAreas = NSHashTable<KeepsSafariBehindArea>.weakObjects()

    /// Whether the click lands where a left click leaves Safari where it is (`keepsSafariBehind()`).
    private func keepsSafariBehind(at event: NSEvent) -> Bool {
        safariStaysBehindAreas.allObjects.contains { area in
            area.window === self && !area.isHiddenOrHasHiddenAncestor
                && area.bounds.contains(area.convert(event.locationInWindow, from: nil))
        }
    }

    /// Needed for renaming; `becomesKeyOnlyIfNeeded` keeps plain clicks from taking focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on the panel act immediately; the panel is almost never key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension View {
    /// A left click here doesn't bring Safari forward, as every other one on the sidebar does: for a button
    /// that brings one of Side Tabs' own windows forward (the Settings gear, #43), which Safari would cover.
    /// The click still goes to the SwiftUI view; this only marks where it lands for the panel.
    func keepsSafariBehind() -> some View {
        background(KeepsSafariBehindMarker())
    }
}

/// The area `keepsSafariBehind()` marks, as big as the view it's behind. It never takes a click, like the
/// hover views (MouseTracking), so the button in front of it gets every one; it tells the panel it's there.
final class KeepsSafariBehindArea: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? SidebarPanel)?.safariStaysBehindAreas.add(self)
    }
}

private struct KeepsSafariBehindMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> KeepsSafariBehindArea { KeepsSafariBehindArea() }
    func updateNSView(_ view: KeepsSafariBehindArea, context: Context) {}
}

/// Background and clipping for the sidebar content.
private struct PanelChrome<Content: View>: View {
    let style: PanelStyle
    @ViewBuilder var content: Content

    var body: some View {
        let fill = style.attached ? SidebarPanel.cornerFill : 0
        let shape = AttachedPanelShape(
            radius: SidebarPanel.cornerRadius,
            cornerFill: fill,
            roundTrailing: !style.attached
        )
        content
            .padding(.trailing, fill)
            .clipShape(shape)
            .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
    }
}

/// A rectangle rounded on the left. When attached, it also fills the two notches between
/// its right edge and Safari's rounded top-left and bottom-left corners.
private struct AttachedPanelShape: Shape {
    var radius: CGFloat
    var cornerFill: CGFloat
    var roundTrailing: Bool

    func path(in rect: CGRect) -> Path {
        let width = rect.width - cornerFill
        let main = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        var path = UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: roundTrailing ? radius : 0,
            topTrailingRadius: roundTrailing ? radius : 0,
            style: .continuous
        ).path(in: main)

        guard cornerFill > 0 else { return path }
        let edge = main.maxX
        let n = cornerFill

        // Top notch: right of the panel, above Safari's top-left corner curve.
        path.move(to: CGPoint(x: edge, y: rect.minY))
        path.addLine(to: CGPoint(x: edge + n, y: rect.minY))
        path.addRelativeArc(center: CGPoint(x: edge + n, y: rect.minY + n), radius: n,
                            startAngle: .degrees(270), delta: .degrees(-90))
        path.closeSubpath()

        // Bottom notch, mirrored.
        path.move(to: CGPoint(x: edge, y: rect.maxY))
        path.addLine(to: CGPoint(x: edge, y: rect.maxY - n))
        path.addRelativeArc(center: CGPoint(x: edge + n, y: rect.maxY - n), radius: n,
                            startAngle: .degrees(180), delta: .degrees(-90))
        path.closeSubpath()
        return path
    }
}
