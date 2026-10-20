import Observation
import SwiftUI

/// Drag-to-reorder for the sidebar.
///
/// This uses a plain drag gesture rather than system drag and drop: the dragged row
/// follows the pointer as a floating copy, and the rows it passes slide apart to open a
/// slot exactly where it will land. Rows have a fixed height, so the slot is computed from
/// positions rather than from which row happens to be under the pointer, which keeps it
/// from flickering.
@Observable
final class SidebarDrag {
    static let coordinateSpace = "sidebar"
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 1
    static var pitch: CGFloat { rowHeight + rowSpacing }

    enum Item: Equatable {
        case tab(BrowserTab, instance: String)
        case bookmark(Bookmark)
        case folder(PinnedFolder)

        var selectionItem: SidebarSelectionItem? {
            switch self {
            case .tab(let tab, let instance): .tab(TabKey(instance: instance, tabId: tab.id))
            case .bookmark(let bookmark): .bookmark(bookmark.id)
            case .folder: nil
            }
        }
    }

    /// Where the item would land: a slot index in one of the lists, or nowhere.
    enum Target: Equatable {
        case none
        case tabs(Int)
        case pinned(folderID: UUID?, index: Int?)
    }

    private(set) var items: [Item] = []
    private(set) var item: Item?
    private(set) var target: Target = .none
    /// Top edge of the floating copy, in sidebar coordinates.
    private(set) var ghostTop: CGFloat = 0
    @ObservationIgnored private var grabOffset: CGFloat = 0

    // Layout reported by the sections, in sidebar coordinates.
    @ObservationIgnored var pinnedFrames: [PinnedItem: CGRect] = [:]
    @ObservationIgnored var bookmarksSectionTop: CGFloat = 0
    @ObservationIgnored var tabRowsTop: CGFloat = 0
    @ObservationIgnored var tabsSectionTop: CGFloat = .greatestFiniteMagnitude

    var isActive: Bool { item != nil }

    /// Every moving row becomes an open slot while the group is over its own list.
    func isSlot(tab: BrowserTab) -> Bool {
        if items.contains(where: { if case .tab(let dragged, _) = $0 { return dragged.id == tab.id }; return false }), case .tabs = target {
            return true
        }
        return false
    }

    func isSlot(bookmark: Bookmark) -> Bool {
        if items.contains(where: { if case .bookmark(let dragged) = $0 { return dragged.id == bookmark.id }; return false }), case .pinned = target {
            return true
        }
        return false
    }

    /// Called as the pointer moves. `rowTop` is the dragged row's top when the drag began.
    func update(
        _ item: Item,
        rowTop: CGFloat,
        value: DragGesture.Value,
        store: TabStore,
        bookmarksVisible: Bool
    ) {
        if self.item == nil {
            guard !NSEvent.modifierFlags.contains(.shift) || item.selectionItem.map(store.validSidebarSelection.contains) == true else { return }
            begin(item, store: store)
            grabOffset = value.startLocation.y - rowTop
            if case .tab = item, let offset = items.firstIndex(of: item) {
                grabOffset += CGFloat(offset) * Self.pitch
            }
        }
        updateTarget(ghostTop: value.location.y - grabOffset, pointerY: value.location.y,
                     store: store, bookmarksVisible: bookmarksVisible)
    }

    func updateTarget(ghostTop: CGFloat, pointerY: CGFloat, store: TabStore, bookmarksVisible: Bool) {
        guard let item else { return }
        self.ghostTop = ghostTop
        let overBookmarks = bookmarksVisible && pointerY < tabsSectionTop
        let newTarget: Target
        if overBookmarks {
            newTarget = pinnedTarget(at: pointerY, item: item, store: store)
        } else if items.allSatisfy({ if case .tab = $0 { return true }; return false }) {
            newTarget = .tabs(slot(rowsTop: tabRowsTop, others: (store.currentWindow.map { store.displayedTabs(in: $0, showBookmarks: bookmarksVisible).count } ?? 0) - items.count))
        } else { newTarget = .none }
        if newTarget != target {
            withAnimation(.snappy(duration: 0.18)) {
                target = newTarget
            }
        }
    }

    /// Capture selection once so live reordering cannot change the drag's membership.
    func begin(_ item: Item, store: TabStore) {
        self.item = item
        let selected = store.validSidebarSelection
        guard let source = item.selectionItem, selected.contains(source), let window = store.currentWindow else {
            items = [item]
            store.clearSidebarSelection()
            return
        }
        items = store.selectableSidebarItems.filter(selected.contains).compactMap { row in
            switch row {
            case .bookmark(let id): return store.bookmark(id).map { .bookmark($0) }
            case .tab(let key): return window.window.tabs.first { $0.id == key.tabId }.map { .tab($0, instance: key.instance) }
            }
        }
    }

    func previewTabs(_ tabs: [BrowserTab]) -> [BrowserTab] {
        guard case .tabs(let index) = target else { return tabs }
        let ids = Set(items.compactMap { if case .tab(let tab, _) = $0 { return tab.id }; return nil })
        let moved = tabs.filter { ids.contains($0.id) }
        var remaining = tabs.filter { !ids.contains($0.id) }
        remaining.insert(contentsOf: moved, at: min(max(index, 0), remaining.count))
        return remaining
    }

    /// The slot whose position the floating copy overlaps most.
    private func slot(rowsTop: CGFloat, others: Int) -> Int {
        let position = ((ghostTop - rowsTop) / Self.pitch).rounded()
        return min(max(Int(position), 0), max(others, 0))
    }

    /// Ends the drag and applies it.
    func finish(store: TabStore, showBookmarks: Bool = true) {
        guard let item else { return }
        let target = self.target
        withAnimation(.snappy(duration: 0.18)) {
            switch (item, target) {
            case (.bookmark, .pinned(let folder, let index)):
                store.moveSidebarItems(items.compactMap(\.selectionItem), toPinned: folder, at: index)
            case (.folder(let folder), .pinned(let parent, let index)):
                store.movePinnedItem(.folder(folder.id), to: parent, at: index)
            case (.tab(_, let instance), .tabs(let index)):
                let tabs = items.compactMap { if case .tab(let tab, _) = $0 { return tab }; return nil }
                store.moveTabs(tabs, instance: instance, to: index, showBookmarks: showBookmarks)
            case (.tab, .pinned(let folder, let index)):
                store.moveSidebarItems(items.compactMap(\.selectionItem), toPinned: folder, at: index)
            default:
                break
            }
            cancel()
        }
    }

    func cancel() { item = nil; items = []; target = .none }

    func isSlot(folder: PinnedFolder) -> Bool {
        if case .folder(let dragged)? = item { return dragged.id == folder.id }
        return false
    }

    private func node(for item: Item) -> PinnedItem? {
        switch item {
        case .folder(let folder): .folder(folder.id)
        case .bookmark(let bookmark): .bookmark(bookmark.id)
        case .tab: nil
        }
    }

    private func pinnedTarget(at y: CGFloat, item: Item, store: TabStore) -> Target {
        let entries = store.visiblePinnedEntries
        guard let entry = entries.first(where: { pinnedFrames[$0.item]?.contains(CGPoint(x: pinnedFrames[$0.item]!.midX, y: y)) == true }),
              let frame = pinnedFrames[entry.item] else { return .pinned(folderID: nil, index: nil) }
        if case .folder(let id) = entry.item, y > frame.minY + 7, y < frame.maxY - 7 {
            guard node(for: item).map({ store.canMovePinnedItem($0, into: id) }) ?? true else { return .none }
            return .pinned(folderID: id, index: nil)
        }
        let parent = store.parentFolder(of: entry.item)
        guard node(for: item).map({ store.canMovePinnedItem($0, into: parent) }) ?? true else { return .none }
        let moving = Set(items.compactMap(node))
        let peers = store.pinnedChildren(of: parent)
        let before = Array(peers.prefix(while: { $0 != entry.item })).filter { !moving.contains($0) }.count
        let extra = y > frame.midY && !moving.contains(entry.item) ? 1 : 0
        return .pinned(folderID: parent, index: before + extra)
    }

    func isInsertionBefore(_ node: PinnedItem, store: TabStore) -> Bool {
        guard case .pinned(let folder, let index?) = target else { return false }
        let moving = Set(items.compactMap(self.node))
        let peers = store.pinnedChildren(of: folder).filter { !moving.contains($0) }
        return peers.indices.contains(index) && peers[index] == node
    }

}

/// The open slot where a dragged row will land.
struct DropSlot: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.accentColor.opacity(0.1))
            .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .frame(height: SidebarDrag.rowHeight)
    }
}

/// The floating copy of the row being dragged.
struct DragGhost: View {
    let item: SidebarDrag.Item
    var count = 1
    @Environment(TabStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            switch item {
            case .tab(let tab, let instance):
                FaviconView(iconURL: tab.favIconUrl, pageURL: tab.url)
                Text(store.displayTitle(for: tab, instance: instance))
                    .lineLimit(1)
            case .folder(let folder):
                Image(systemName: "folder.fill").frame(width: 16)
                Text(folder.name).lineLimit(1)
            case .bookmark(let bookmark):
                FaviconView(iconURL: bookmark.faviconURL, pageURL: bookmark.url)
                Text(bookmark.title)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if count > 1 {
                Text("\(count)").font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: SidebarDrag.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        )
        .scaleEffect(1.02)
    }
}

extension View {
    /// Makes a row draggable within the sidebar.
    func sidebarDraggable(
        _ item: SidebarDrag.Item,
        drag: SidebarDrag,
        store: TabStore,
        settings: AppSettings,
        rowTop: CGFloat,
        enabled: Bool
    ) -> some View {
        gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(SidebarDrag.coordinateSpace))
                .onChanged { value in
                    guard enabled else { return }
                    drag.update(
                        item,
                        rowTop: rowTop,
                        value: value,
                        store: store,
                        bookmarksVisible: settings.showBookmarks
                    )
                }
                .onEnded { _ in
                    drag.finish(store: store, showBookmarks: settings.showBookmarks)
                }
        )
    }

    /// Reports this view's top edge in sidebar coordinates.
    func onSidebarTop(_ action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(SidebarDrag.coordinateSpace)).minY
        } action: { top in
            action(top)
        }
    }
}
