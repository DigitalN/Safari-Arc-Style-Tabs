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
    }

    /// Where the item would land: a slot index in one of the lists, or nowhere.
    enum Target: Equatable {
        case none
        case tabs(Int)
        case pinned(folderID: UUID?, index: Int?)
    }

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

    /// The row being dragged is drawn as the open slot while it's over its own list.
    func isSlot(tab: BrowserTab) -> Bool {
        if case .tab(let dragged, _)? = item, dragged.id == tab.id, case .tabs = target {
            return true
        }
        return false
    }

    func isSlot(bookmark: Bookmark) -> Bool {
        if case .bookmark(let dragged)? = item, dragged.id == bookmark.id, case .pinned = target {
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
            self.item = item
            grabOffset = value.startLocation.y - rowTop
        }
        ghostTop = value.location.y - grabOffset
        let overBookmarks = bookmarksVisible && value.location.y < tabsSectionTop
        let newTarget: Target
        if overBookmarks {
            newTarget = pinnedTarget(at: value.location.y, item: item, store: store)
        } else if case .tab = item {
            newTarget = .tabs(slot(rowsTop: tabRowsTop, others: (store.currentWindow.map { store.displayedTabs(in: $0, showBookmarks: bookmarksVisible).count } ?? 0) - 1))
        } else { newTarget = .none }
        if newTarget != target {
            withAnimation(.snappy(duration: 0.18)) {
                target = newTarget
            }
        }
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
            case (.bookmark(let bookmark), .pinned(let folder, let index)):
                store.movePinnedItem(.bookmark(bookmark.id), to: folder, at: index)
            case (.folder(let folder), .pinned(let parent, let index)):
                store.movePinnedItem(.folder(folder.id), to: parent, at: index)
            case (.tab(let tab, let instance), .tabs(let index)):
                store.moveTab(tab, instance: instance, to: index, showBookmarks: showBookmarks)
            case (.tab(let tab, let instance), .pinned(let folder, let index)):
                store.addBookmark(from: tab, instance: instance, at: index, folderID: folder)
            default:
                break
            }
            self.item = nil
            self.target = .none
        }
    }

    func cancel() { item = nil; target = .none }

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
        let peers = store.pinnedChildren(of: parent)
        let before = Array(peers.prefix(while: { $0 != entry.item })).filter { $0 != node(for: item) }.count
        let extra = y > frame.midY && entry.item != node(for: item) ? 1 : 0
        return .pinned(folderID: parent, index: before + extra)
    }

    func isInsertionBefore(_ node: PinnedItem, store: TabStore) -> Bool {
        guard case .pinned(let folder, let index?) = target else { return false }
        let peers = store.pinnedChildren(of: folder).filter { $0 != item.flatMap(self.node) }
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
