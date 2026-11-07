import SwiftUI

struct TabRow: View {
    let tab: BrowserTab
    let instance: String

    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarDrag.self) private var drag
    @State private var hovering = false
    @State private var rowTop: CGFloat = 0
    /// True while a press is in progress, so the drag gesture's repeated updates don't repeat
    /// it. A gesture state rather than `@State`: SwiftUI resets it when a press ends *or is
    /// cancelled*, and doesn't call `onEnded` for a cancelled one, so a single cancelled press
    /// can't leave the row ignoring every press after it.
    @GestureState private var pressInProgress = false
    /// Where the mute and close buttons are, in the window's coordinates. Presses on them
    /// belong to the button, not the row. Only trusted while the button is showing.
    @State private var muteFrame = CGRect.zero
    @State private var closeFrame = CGRect.zero

    private var key: TabKey { TabKey(instance: instance, tabId: tab.id) }
    private var isSlot: Bool { drag.isSlot(tab: tab) }
    private var isRenaming: Bool { store.renaming == .tab(key) }
    private var showsMute: Bool { tab.audible || tab.muted }
    private var showsClose: Bool {
        !isRenaming && (settings.closeButtonMode == .always || hovering || tab.active)
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                FaviconView(iconURL: tab.favIconUrl, pageURL: tab.url)
                    .opacity(tab.loading ? 0.35 : 1)
                if tab.loading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .frame(width: 16, height: 16)

            if isRenaming {
                RenameField(
                    text: store.displayTitle(for: tab, instance: instance),
                    onCommit: store.commitRename,
                    onCancel: store.cancelRename
                )
            } else {
                Text(store.displayTitle(for: tab, instance: instance))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if showsMute {
                SidebarIconButton(
                    systemImage: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    help: tab.muted ? "Unmute Tab" : "Mute Tab",
                    size: 10
                ) {
                    store.setMuted(!tab.muted, tab: tab, instance: instance)
                }
                .onWindowFrame { muteFrame = $0 }
            }

            ZStack {
                if showsClose {
                    SidebarIconButton(systemImage: "xmark", help: "Close Tab", size: 9) {
                        store.close([tab], instance: instance)
                    }
                    .onWindowFrame { closeFrame = $0 }
                } else if tab.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 20, height: 20)
        }
        .font(.system(size: 13))
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: SidebarDrag.rowHeight)
        .background(RowBackground(isActive: tab.active, isHovering: hovering && !drag.isActive))
        .opacity(isSlot ? 0 : 1)
        .overlay {
            if isSlot {
                DropSlot()
            }
        }
        .background(MouseTracking(onHover: { hovering = $0 }, onMiddleClick: { store.close([tab], instance: instance) }))
        .contentShape(Rectangle())
        // Safari's own tab bar switches on mouse-down, so this does too: waiting for the
        // mouse-up would add the length of the click to every switch. The second press of a
        // double-click renames instead. A separate double-tap gesture would make SwiftUI hold
        // every single click for the double-click interval, so the click count is read here.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($pressInProgress) { value, inProgress, _ in
                    guard !inProgress else { return }
                    inProgress = true
                    press(at: value.startLocation)
                }
        )
        .sidebarDraggable(
            .tab(tab, instance: instance),
            drag: drag,
            store: store,
            settings: settings,
            rowTop: rowTop,
            enabled: !isRenaming
        )
        .onSidebarTop { rowTop = $0 }
        .contextMenu { contextMenu }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tab.active ? [.isButton, .isSelected] : .isButton)
    }

    /// Whether a press at `point` (window coordinates) landed on the mute or close button.
    /// Decided from where the press landed, not from hover state: a button that disappears
    /// under the pointer never reports the pointer leaving, which would leave the row
    /// ignoring every press.
    private func isOnControl(_ point: CGPoint) -> Bool {
        (showsMute && muteFrame.containsCircle(point)) || (showsClose && closeFrame.containsCircle(point))
    }

    /// The first event of a press. Runs while the mouse-down is being dispatched, which is
    /// when `NSApp.currentEvent` still has the click count.
    private func press(at point: CGPoint) {
        guard !isRenaming, !isOnControl(point) else { return }
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            store.beginRename(.tab(key))
        } else {
            store.activate(tab, instance: instance)
        }
    }

    private var tooltip: String {
        let page = store.pageTitle(for: tab)
        let shown = store.displayTitle(for: tab, instance: instance)
        var lines = shown == page ? [page] : [shown, page]
        if let url = tab.url, !url.isEmpty {
            lines.append(url)
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private var contextMenu: some View {
        Button("Rename Tab…") { store.beginRename(.tab(key)) }
        if store.hasCustomName(key) {
            Button("Reset Name") { store.resetName(key) }
        }
        Divider()
        Button("Add to Bookmarks") { store.addBookmark(from: tab, instance: instance) }
            .disabled(tab.url == nil)
        Button("Copy Link") { store.copyLink(tab.url) }
            .disabled(tab.url == nil)
        Button("Duplicate Tab") { store.duplicate(tab, instance: instance) }
        Button("Reload Tab") { store.reload(tab, instance: instance) }
        if tab.audible || tab.muted {
            Button(tab.muted ? "Unmute Tab" : "Mute Tab") { store.setMuted(!tab.muted, tab: tab, instance: instance) }
        }
        Divider()
        Button("Close Tab") { store.close([tab], instance: instance) }
        Button("Close Other Tabs") { store.closeOtherTabs(than: tab, instance: instance) }
        Button("Close Tabs Below") { store.closeTabsBelow(tab, instance: instance) }
    }
}

private extension CGRect {
    /// Whether `point` is inside the circle that fills this (square) rect, which is the shape
    /// of the row's icon buttons.
    func containsCircle(_ point: CGPoint) -> Bool {
        !isEmpty && hypot(point.x - midX, point.y - midY) <= min(width, height) / 2
    }
}

struct NewTabRow: View {
    @Environment(TabStore.self) private var store
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16)
            Text("New Tab")
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: SidebarDrag.rowHeight)
        .background(RowBackground(isActive: false, isHovering: hovering))
        .background(MouseTracking(onHover: { hovering = $0 }))
        .contentShape(Rectangle())
        .onTapGesture { store.newTab() }
        .accessibilityAddTraits(.isButton)
    }
}

/// Reads the first URL from dropped items, e.g. a link dragged from a web page.
func loadDroppedURL(from providers: [NSItemProvider], completion: @escaping @MainActor (URL) -> Void) -> Bool {
    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
    _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        DispatchQueue.main.async {
            completion(url)
        }
    }
    return true
}
