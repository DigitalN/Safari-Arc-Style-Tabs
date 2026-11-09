import Observation
import SwiftUI

/// Drag-to-reorder for the sidebar.
///
/// This uses a plain drag gesture rather than system drag and drop: the dragged row
/// follows the pointer as a floating copy, and the rows it passes slide apart to open a
/// slot exactly where it will land. Rows have a fixed height, so the slot is computed from
/// positions rather than from which row happens to be under the pointer, which keeps it
/// from flickering. Favorites are a grid of tiles (#34) whose cells have fixed positions too,
/// so there the slot is the cell under the pointer.
@Observable
final class SidebarDrag {
    static let coordinateSpace = "sidebar"
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 1
    static var pitch: CGFloat { rowHeight + rowSpacing }

    enum Item: Equatable {
        case tab(BrowserTab, instance: String)
        /// A favorite's tile.
        case favorite(Bookmark)
        /// A row in the Pinned list the sidebar shows.
        case pinned(Bookmark)
    }

    /// Where the item would land: a slot index in one of the lists, or nowhere. `favorites` and `pinned`
    /// are the lists the sidebar shows (`TabStore.currentFavoritesList` and `currentPinnedList`).
    enum Target: Equatable {
        case none
        case tabs(Int)
        case favorites(Int)
        case pinned(Int)
    }

    /// What the sections hold while the pointer moves, which bounds the slots.
    struct Counts {
        /// Both nil when there are no Favorites or Pinned sections (a private window).
        var favorites: Int?
        var pinned: Int?
        var tabs: Int
        /// Whether Favorites and Pinned show (Settings). Without them every tab is in the Tabs list.
        var sectionsShown: Bool
    }

    private(set) var item: Item?
    private(set) var target: Target = .none
    /// Top left of the floating copy, in sidebar coordinates. A row's copy spans the width, so only
    /// its top moves.
    private(set) var ghostOrigin: CGPoint = .zero
    /// Whether the floating copy is drawn as a tile: over Favorites, which is where it would land as
    /// a tile, or a tile dragged to where it can't land.
    private(set) var ghostIsTile = false
    /// Where in the dragged row or tile the pointer took hold of it.
    @ObservationIgnored private var grab: CGPoint = .zero
    /// Whether Favorites and Pinned show, which decides whether their tabs are in the Tabs list.
    @ObservationIgnored private var sectionsVisible = true

    // Layout reported by the sections, in sidebar coordinates.
    /// The favorites' grid, or the drop area that stands in for it during a drag while there are none.
    @ObservationIgnored var favoritesFrame: CGRect = .zero
    @ObservationIgnored var favoritesMetrics = TileGridMetrics(width: 0)
    @ObservationIgnored var pinnedRowsTop: CGFloat = 0
    @ObservationIgnored var pinnedSectionTop: CGFloat = 0
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

    func isSlot(favorite: Bookmark) -> Bool {
        if case .favorite(let dragged)? = item, dragged.id == favorite.id, case .favorites = target {
            return true
        }
        return false
    }

    func isSlot(pinned: Bookmark) -> Bool {
        if case .pinned(let dragged)? = item, dragged.id == pinned.id, case .pinned = target {
            return true
        }
        return false
    }

    /// Called as the pointer moves. `origin` is the dragged row's or tile's top left when the drag began.
    func update(_ item: Item, origin: CGPoint, value: DragGesture.Value, counts: Counts) {
        let startsAsTile: Bool
        if case .favorite = item { startsAsTile = true } else { startsAsTile = false }
        if self.item == nil {
            self.item = item
            grab = CGPoint(x: value.startLocation.x - origin.x, y: value.startLocation.y - origin.y)
        }
        sectionsVisible = counts.sectionsShown
        let pointer = value.location
        // A row's copy keeps the pointer where it took hold of the row; a tile's, wherever it took hold
        // of the tile. One of a kind it didn't start as is centred on the pointer.
        let tile = favoritesMetrics.tile
        let rowTop = pointer.y - (startsAsTile ? Self.rowHeight / 2 : grab.y)
        let tileGrab = startsAsTile ? grab : CGPoint(x: tile / 2, y: tile / 2)
        let tileOrigin = CGPoint(x: pointer.x - tileGrab.x, y: pointer.y - tileGrab.y)

        // Favorites are at the top, then Pinned, then Tabs. A private window has Tabs only.
        enum Region { case favorites, pinned, tabs }
        let region: Region
        if !counts.sectionsShown || counts.favorites == nil || counts.pinned == nil {
            region = .tabs
        } else if pointer.y < pinnedSectionTop {
            region = .favorites
        } else if pointer.y < tabsSectionTop {
            region = .pinned
        } else {
            region = .tabs
        }

        let newTarget: Target
        switch (item, region) {
        case (.tab, .tabs):
            newTarget = .tabs(slot(rowTop: rowTop, rowsTop: tabRowsTop, others: counts.tabs - 1))
        case (.pinned, .pinned):
            newTarget = .pinned(slot(rowTop: rowTop, rowsTop: pinnedRowsTop, others: (counts.pinned ?? 0) - 1))
        case (.tab, .pinned), (.favorite, .pinned):
            newTarget = .pinned(slot(rowTop: rowTop, rowsTop: pinnedRowsTop, others: counts.pinned ?? 0))
        case (.favorite, .favorites):
            newTarget = .favorites(gridSlot(at: pointer, others: (counts.favorites ?? 0) - 1))
        case (.tab, .favorites), (.pinned, .favorites):
            newTarget = .favorites(gridSlot(at: pointer, others: counts.favorites ?? 0))
        case (.favorite, .tabs), (.pinned, .tabs):
            newTarget = .none
        }

        let asTile: Bool
        switch newTarget {
        case .favorites: asTile = true
        case .none: asTile = startsAsTile
        case .tabs, .pinned: asTile = false
        }
        ghostIsTile = asTile
        ghostOrigin = asTile ? tileOrigin : CGPoint(x: 0, y: rowTop)
        if newTarget != target {
            withAnimation(.snappy(duration: 0.18)) {
                target = newTarget
            }
        }
    }

    /// The slot whose position the floating row overlaps most.
    private func slot(rowTop: CGFloat, rowsTop: CGFloat, others: Int) -> Int {
        let position = ((rowTop - rowsTop) / Self.pitch).rounded()
        guard position.isFinite else { return 0 }
        return min(max(Int(position), 0), max(others, 0))
    }

    /// The favorites' cell under the pointer. The cells stay where they are while the tiles move
    /// through them, so this doesn't flicker.
    private func gridSlot(at pointer: CGPoint, others: Int) -> Int {
        favoritesMetrics.slot(at: CGPoint(x: pointer.x - favoritesFrame.minX, y: pointer.y - favoritesFrame.minY), count: others)
    }

    /// Ends the drag and applies it.
    func finish(store: TabStore) {
        guard let item else { return }
        let target = self.target
        withAnimation(.snappy(duration: 0.18)) {
            switch (item, target) {
            case (.favorite(let bookmark), .favorites(let index)), (.pinned(let bookmark), .favorites(let index)):
                if let list = store.currentFavoritesList {
                    store.moveBookmark(bookmark.id, to: list, at: index)
                }
            case (.favorite(let bookmark), .pinned(let index)), (.pinned(let bookmark), .pinned(let index)):
                if let list = store.currentPinnedList {
                    store.moveBookmark(bookmark.id, to: list, at: index)
                }
            case (.tab(let tab, let instance), .tabs(let index)):
                store.moveTab(tab, instance: instance, toListedSlot: index, bookmarksShown: sectionsVisible)
            case (.tab(let tab, let instance), .favorites(let index)):
                if let list = store.currentFavoritesList {
                    store.addBookmark(from: tab, instance: instance, to: list, at: index)
                }
            case (.tab(let tab, let instance), .pinned(let index)):
                if let list = store.currentPinnedList {
                    store.addBookmark(from: tab, instance: instance, to: list, at: index)
                }
            default:
                break
            }
            self.item = nil
            self.target = .none
        }
    }

    /// Forgets a drag whose gesture was cancelled before it ended (SwiftUI doesn't call `onEnded`
    /// for a cancelled one), so the row it left open doesn't stay open.
    func cancel() {
        guard item != nil else { return }
        withAnimation(.snappy(duration: 0.18)) {
            item = nil
            target = .none
        }
    }

    /// Pinned slot for a link dropped from outside the sidebar at `y` (section coordinates).
    func pinnedIndex(forDropAt y: CGFloat, count: Int) -> Int {
        let rowsOffset = pinnedRowsTop - pinnedSectionTop
        let position = ((y - rowsOffset) / Self.pitch).rounded(.down)
        guard position.isFinite else { return count }
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

/// The floating copy of the row or tile being dragged.
struct DragGhost: View {
    let item: SidebarDrag.Item
    /// Drawn as a favorite's tile of this size, rather than as a row.
    let tileSize: CGFloat?
    @Environment(TabStore.self) private var store

    private var page: (icon: String?, url: String?, title: String) {
        switch item {
        case .tab(let tab, let instance):
            (tab.favIconUrl, tab.url, store.displayTitle(for: tab, instance: instance))
        case .favorite(let bookmark), .pinned(let bookmark):
            (bookmark.faviconURL, bookmark.url, bookmark.title)
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: tileSize == nil ? 7 : FavoriteTile.cornerRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    var body: some View {
        if let tileSize {
            FaviconView(iconURL: page.icon, pageURL: page.url, size: FavoriteTile.iconSize)
                .frame(width: tileSize, height: tileSize)
                .background(background)
                .scaleEffect(1.04)
        } else {
            HStack(spacing: 8) {
                FaviconView(iconURL: page.icon, pageURL: page.url)
                Text(page.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: SidebarDrag.rowHeight)
            .background(background)
            .scaleEffect(1.02)
        }
    }
}

extension View {
    /// The one mouse gesture a sidebar row or tile has: it reacts to the press at once, and turns
    /// into a drag to reorder when the pointer moves.
    ///
    /// It has to be a single gesture. A row that has a press gesture (which starts the moment the
    /// button goes down) and a separate drag gesture outside it never gets the drag: SwiftUI
    /// lets the inner one win, and a press with no minimum distance never fails.
    ///
    /// - `onPress` runs on the first update of a press, with where it started (sidebar
    ///   coordinates), and says whether the row takes it. A press it declines does nothing else.
    /// - `onClick` runs when the button goes up and the press didn't turn into a drag. A press
    ///   that did can never also be a click.
    /// - `dragEnabled` is read at every update, so a row that starts renaming mid-press stops
    ///   reordering.
    /// - `rowTop` and `rowLeft` are the row's or tile's top left in sidebar coordinates. Rows span
    ///   the width, so they leave `rowLeft` at 0.
    func sidebarRowGesture(
        _ item: SidebarDrag.Item,
        drag: SidebarDrag,
        store: TabStore,
        settings: AppSettings,
        rowTop: CGFloat,
        rowLeft: CGFloat = 0,
        dragEnabled: Bool,
        onPress: @escaping (CGPoint) -> Bool,
        onClick: (() -> Void)? = nil
    ) -> some View {
        modifier(SidebarRowGesture(
            item: item, drag: drag, store: store, settings: settings, origin: CGPoint(x: rowLeft, y: rowTop),
            dragEnabled: dragEnabled, onPress: onPress, onClick: onClick
        ))
    }

    /// Reports this view's top edge in sidebar coordinates.
    func onSidebarTop(_ action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .named(SidebarDrag.coordinateSpace)).minY
        } action: { top in
            action(top)
        }
    }

    /// Reports this view's frame in sidebar coordinates, which is where a row's gesture reports
    /// the pointer. They don't change when the list scrolls.
    func onSidebarFrame(_ action: @escaping (CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(SidebarDrag.coordinateSpace))
        } action: { frame in
            action(frame)
        }
    }
}

private struct SidebarRowGesture: ViewModifier {
    let item: SidebarDrag.Item
    let drag: SidebarDrag
    let store: TabStore
    let settings: AppSettings
    let origin: CGPoint
    let dragEnabled: Bool
    let onPress: (CGPoint) -> Bool
    let onClick: (() -> Void)?

    /// The press in progress. A gesture state rather than `@State`: SwiftUI resets it when a press
    /// ends *or is cancelled*, and doesn't call `onEnded` for a cancelled one, so a single
    /// cancelled press can't leave the row ignoring every press after it.
    @GestureState private var press = RowPress()

    /// What the sections hold now.
    private var counts: SidebarDrag.Counts {
        let selection = store.currentWindow
        return SidebarDrag.Counts(
            favorites: store.currentFavoritesList.map { store.bookmarks(in: $0).count },
            pinned: store.currentPinnedList.map { store.bookmarks(in: $0).count },
            tabs: selection.map {
                store.tabsListed(in: $0.window, instance: $0.instance, bookmarksShown: settings.showBookmarks).count
            } ?? 0,
            sectionsShown: settings.showBookmarks
        )
    }

    func body(content: Content) -> some View {
        // simultaneousGesture, so the row's buttons (mute, close) and the rename field still
        // get their own presses, which `onPress` tells apart by where the press landed.
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(SidebarDrag.coordinateSpace))
                .updating($press) { value, press, _ in
                    let isDrag = press.update(translation: value.translation) {
                        // Only one press can be going on, so a drag still showing is one whose
                        // gesture was cancelled.
                        drag.cancel()
                        return onPress(value.startLocation)
                    }
                    guard isDrag, dragEnabled else { return }
                    drag.update(item, origin: origin, value: value, counts: counts)
                }
                .onEnded { _ in
                    // Whether it was a drag is the drag's own state: it began (and stays) once
                    // the pointer moved far enough, even if it came back to where it started.
                    let wasDrag = drag.isActive
                    drag.finish(store: store)
                    if !wasDrag {
                        onClick?()
                    }
                }
        )
    }
}
