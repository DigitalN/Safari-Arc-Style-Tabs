import SwiftUI
import UniformTypeIdentifiers

struct TabRow: View {
    let tab: BrowserTab
    let instance: String

    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var hovering = false

    private var key: TabKey { TabKey(instance: instance, tabId: tab.id) }
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
        .frame(height: 30)
        .background(RowBackground(isActive: tab.active, isHovering: hovering))
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
        .contextMenu { contextMenu }
        .onDrag {
            store.beginDrag(.tab(key))
            if let url = tab.url.flatMap(URL.init(string:)) {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider(object: store.displayTitle(for: tab, instance: instance) as NSString)
        }
        .onDrop(of: [.url, .plainText], delegate: TabDropDelegate(target: tab, instance: instance, store: store))
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
        .frame(height: 30)
        .background(RowBackground(isActive: false, isHovering: hovering))
        .background(MouseTracking(onHover: { hovering = $0 }))
        .contentShape(Rectangle())
        .onTapGesture { store.newTab() }
        .accessibilityAddTraits(.isButton)
    }
}

/// Reorders tabs while dragging; opens dropped links in a new tab.
struct TabDropDelegate: DropDelegate {
    let target: BrowserTab?
    let instance: String
    let store: TabStore

    func dropEntered(info: DropInfo) {
        guard let target, case .tab(let key)? = store.dragging, key.instance == instance else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            store.previewMove(tab: key, over: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if case .tab? = store.dragging {
            return DropProposal(operation: .move)
        }
        return DropProposal(operation: store.dragging == nil ? .copy : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        switch store.dragging {
        case .tab?:
            store.finishDrag()
            return true
        case .bookmark?:
            store.finishDrag()
            return false
        case nil:
            return loadDroppedURL(info) { url in store.newTab(url: url.absoluteString) }
        }
    }
}

/// Reads the first URL from a drop, e.g. a link dragged from a web page.
func loadDroppedURL(_ info: DropInfo, completion: @escaping @MainActor (URL) -> Void) -> Bool {
    guard let provider = info.itemProviders(for: [.url]).first else { return false }
    _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        DispatchQueue.main.async {
            completion(url)
        }
    }
    return true
}
