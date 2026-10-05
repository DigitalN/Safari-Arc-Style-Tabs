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
    }

    /// Where the item would land: a slot index in one of the lists, or nowhere.
    enum Target: Equatable {
        case none
        case tabs(Int)
        case bookmarks(Int)
    }

    private(set) var item: Item?
    private(set) var target: Target = .none
    /// Top edge of the floating copy, in sidebar coordinates.
    private(set) var ghostTop: CGFloat = 0
    @ObservationIgnored private var grabOffset: CGFloat = 0

    // Layout reported by the sections, in sidebar coordinates.
    @ObservationIgnored var bookmarkRowsTop: CGFloat = 0
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
        if case .bookmark(let dragged)? = item, dragged.id == bookmark.id, case .bookmarks = target {
            return true
        }
        return false
    }

    /// Called as the pointer moves. `rowTop` is the dragged row's top when the drag began.
    func update(
        _ item: Item,
        rowTop: CGFloat,
        value: DragGesture.Value,
        bookmarkCount: Int,
        tabCount: Int,
        bookmarksVisible: Bool
    ) {
        if self.item == nil {
            self.item = item
            grabOffset = value.startLocation.y - rowTop
        }
        ghostTop = value.location.y - grabOffset

        let overBookmarks = bookmarksVisible && value.location.y < tabsSectionTop
        let newTarget: Target
        switch (item, overBookmarks) {
        case (.bookmark, true):
            newTarget = .bookmarks(slot(rowsTop: bookmarkRowsTop, others: bookmarkCount - 1))
        case (.tab, true):
            newTarget = .bookmarks(slot(rowsTop: bookmarkRowsTop, others: bookmarkCount))
        case (.tab, false):
            newTarget = .tabs(slot(rowsTop: tabRowsTop, others: tabCount - 1))
        case (.bookmark, false):
            newTarget = .none
        }
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
    func finish(store: TabStore) {
        guard let item else { return }
        let target = self.target
        withAnimation(.snappy(duration: 0.18)) {
            switch (item, target) {
            case (.bookmark(let bookmark), .bookmarks(let index)):
                store.moveBookmark(bookmark.id, to: index)
            case (.tab(let tab, let instance), .tabs(let index)):
                store.moveTab(tab, instance: instance, to: index)
            case (.tab(let tab, let instance), .bookmarks(let index)):
                store.addBookmark(from: tab, instance: instance, at: index)
            default:
                break
            }
            self.item = nil
            self.target = .none
        }
    }

    /// Bookmark slot for a link dropped from outside the sidebar at `y` (section coordinates).
    func bookmarkIndex(forDropAt y: CGFloat, count: Int) -> Int {
        let rowsOffset = bookmarkRowsTop - bookmarksSectionTop
        let position = ((y - rowsOffset) / Self.pitch).rounded(.down)
        return min(max(Int(position), 0), count)
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
                        bookmarkCount: store.bookmarks.count,
                        tabCount: store.currentWindow?.window.tabs.count ?? 0,
                        bookmarksVisible: settings.showBookmarks
                    )
                }
                .onEnded { _ in
                    drag.finish(store: store)
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
