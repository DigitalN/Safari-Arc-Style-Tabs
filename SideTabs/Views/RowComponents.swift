import AppKit
import SwiftUI

/// Hover detection that works even though Side Tabs is never the active app (SwiftUI's own
/// hover tracking only runs in the active app). (Middle clicks are not handled here: this view
/// never gets them, see SidebarPanel.)
struct MouseTracking: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onHover = onHover
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                onHover?(false)
            }
        }

        /// Never claims a click: they all go to the SwiftUI row.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct RowBackground: View {
    var isActive: Bool
    var isHovering: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(isActive ? 0.12 : isHovering ? 0.055 : 0))
    }
}

extension View {
    /// Reports this view's frame in the window's coordinates, whenever it changes.
    func onWindowFrame(_ action: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            action(frame)
        }
    }
}

struct SidebarIconButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 11
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(MouseTracking(onHover: { hovering = $0 }))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Inline text field used to rename tabs and bookmarks.
struct RenameField: View {
    @State var text: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { onCommit(text) }
            .onExitCommand { onCancel() }
            .onAppear {
                DispatchQueue.main.async { focused = true }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    onCommit(text)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                if note.object is SidebarPanel {
                    onCommit(text)
                }
            }
    }
}

struct SectionHeader<Accessory: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 24)
    }
}
