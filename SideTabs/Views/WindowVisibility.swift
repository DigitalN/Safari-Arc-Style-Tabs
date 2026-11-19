import AppKit
import SwiftUI

/// Where the window showing a view is. Side Tabs keeps its windows when they close or hide (the sidebar's panel is
/// ordered out, Settings and Setup are kept for next time), so their views never disappear, and `onDisappear` and
/// `.task` can't tell. Spinners and anything that repeats go by this instead (#83).
struct WindowVisibility: Equatable {
    /// Ordered in: open, though perhaps covered by other windows.
    var isOpen = false
    /// Open and at least partly on screen: not covered, not on another Space, the display awake.
    var isOnScreen = false
}

extension EnvironmentValues {
    /// Whether the sidebar's window is on screen, for its animations: a spinner in a hidden or covered sidebar
    /// would redraw it for nobody (#83). Set by `tracksWindowVisibility()`.
    @Entry var windowIsOnScreen = true
}

extension View {
    /// Calls `action` with where this view's window is: when the view moves into a window, and each time the
    /// window opens, closes, or is covered or uncovered.
    func onWindowVisibilityChange(_ action: @escaping (WindowVisibility) -> Void) -> some View {
        background(WindowVisibilityWatcher(action: action))
    }

    /// Sets `windowIsOnScreen` for this view and everything in it.
    func tracksWindowVisibility() -> some View {
        modifier(TracksWindowVisibility())
    }
}

private struct TracksWindowVisibility: ViewModifier {
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .environment(\.windowIsOnScreen, isOnScreen)
            .onWindowVisibilityChange { visibility in
                if isOnScreen != visibility.isOnScreen {
                    isOnScreen = visibility.isOnScreen
                }
            }
    }
}

private struct WindowVisibilityWatcher: NSViewRepresentable {
    let action: (WindowVisibility) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher(action: action) }

    func updateNSView(_ watcher: Watcher, context: Context) { watcher.action = action }

    final class Watcher: NSView {
        var action: (WindowVisibility) -> Void
        private var tokens: [NSObjectProtocol] = []
        private var reported: WindowVisibility?

        init(action: @escaping (WindowVisibility) -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            if let window {
                // Ordering a window out or in, covering it, another Space and the display sleeping all change its
                // occlusion state; closing it also posts willClose, while it's still ordered in.
                let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification]
                tokens = names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                        let closing = note.name == NSWindow.willCloseNotification
                        MainActor.assumeIsolated { self?.report(closing: closing) }
                    }
                }
            }
            // Not from inside AppKit's or SwiftUI's update of the view tree.
            DispatchQueue.main.async { [weak self] in self?.report(closing: false) }
        }

        private func report(closing: Bool) {
            var visibility = WindowVisibility()
            if let window, !closing {
                visibility.isOpen = window.isVisible
                visibility.isOnScreen = window.isVisible && window.occlusionState.contains(.visible)
            }
            guard visibility != reported else { return }
            reported = visibility
            action(visibility)
        }

        /// Clicks go to the views in front of it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
