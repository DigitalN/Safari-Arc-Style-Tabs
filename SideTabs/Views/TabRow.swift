import SwiftUI

struct TabRow: View {
    let tab: BrowserTab
    let instance: String

    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarDrag.self) private var drag
    @State private var hovering = false
    @State private var rowTop: CGFloat = 0

    private var key: TabKey { TabKey(instance: instance, tabId: tab.id) }
    private var isSlot: Bool { drag.isSlot(tab: tab) }
    private var isRenaming: Bool { store.renaming == .tab(key) }
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

            if tab.audible || tab.muted {
                SidebarIconButton(
                    systemImage: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    help: tab.muted ? "Unmute Tab" : "Mute Tab",
                    size: 10
                ) {
                    store.setMuted(!tab.muted, tab: tab, instance: instance)
                }
            }

            ZStack {
                if showsClose {
                    SidebarIconButton(systemImage: "xmark", help: "Close Tab", size: 9) {
                        store.close([tab], instance: instance)
                    }
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
        .onTapGesture {
            // A separate double-tap gesture would make SwiftUI hold every single click
            // for the double-click interval, so read the click count instead.
            guard !isRenaming else { return }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                store.beginRename(.tab(key))
            } else {
                store.activate(tab, instance: instance)
            }
        }
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
