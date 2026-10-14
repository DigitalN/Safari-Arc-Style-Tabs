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
    var onMouseDown: (() -> Void)?
    var onSpaceSwipe: ((Int) -> Void)?
    private var spaceSwipe = SpaceSwipe()

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, event.hasPreciseScrollingDeltas,
           !event.phase.isEmpty || !event.momentumPhase.isEmpty {
            let visibleWidth = frame.width - (style.attached ? Self.cornerFill : 0)
            let point = event.locationInWindow
            if point.x >= 0, point.x < visibleWidth, point.y >= 0, point.y < frame.height {
                // Normalize to finger movement so left means next with either
                // setting of macOS Natural Scrolling.
                let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
                let result = spaceSwipe.update(x: dx, y: event.scrollingDeltaY,
                    began: event.phase.contains(.began), ended: event.phase.contains(.ended),
                    cancelled: event.phase.contains(.cancelled), momentum: !event.momentumPhase.isEmpty)
                if let direction = result.direction { onSpaceSwipe?(direction) }
                if result.consume { return }
            } else { spaceSwipe.reset() }
        }
        if event.type == .leftMouseDown || event.type == .otherMouseDown {
            onMouseDown?()
        }
        super.sendEvent(event)
    }

    /// Needed for renaming; `becomesKeyOnlyIfNeeded` keeps plain clicks from taking focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on the panel act immediately; the panel is almost never key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
