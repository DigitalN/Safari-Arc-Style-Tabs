import SwiftUI

/// The favorites (#34): a grid of square tiles at the top of the sidebar, shared by every profile
/// and shown in private windows too. With no favorites it takes no room, except during a drag, when
/// a drop area shows where the grid would be.
struct FavoritesSection: View {
    @Environment(TabStore.self) private var store
    @Environment(SidebarDrag.self) private var drag
    @State private var width: CGFloat = 0

    private enum Slot: Identifiable {
        case favorite(Bookmark)
        case dropSlot

        var id: String {
            switch self {
            case .favorite(let favorite): favorite.id.uuidString
            case .dropSlot: "drop-slot"
            }
        }
    }

    /// Favorites in display order. While a favorite is dragged over the grid it moves to the target
    /// cell (and draws itself as the slot); a dragged tab or pinned item gets a slot of its own.
    private var slots: [Slot] {
        var favorites = store.favorites
        switch (drag.item, drag.target) {
        case (.favorite(let dragged)?, .favorites(let index)):
            if let from = favorites.firstIndex(where: { $0.id == dragged.id }) {
                let moved = favorites.remove(at: from)
                favorites.insert(moved, at: min(index, favorites.count))
            }
            return favorites.map(Slot.favorite)
        case (.tab?, .favorites(let index)), (.pinned?, .favorites(let index)):
            var slots = favorites.map(Slot.favorite)
            slots.insert(.dropSlot, at: min(index, slots.count))
            return slots
        default:
            return favorites.map(Slot.favorite)
        }
    }

    private var metrics: TileGridMetrics { TileGridMetrics(width: width) }

    private var isDropTarget: Bool {
        if case .favorites = drag.target { true } else { false }
    }

    /// The favorite being renamed: tiles have no room for the name, so it's edited in a row below.
    private var renamed: Bookmark? {
        guard case .bookmark(let id) = store.renaming else { return nil }
        return store.favorites.first { $0.id == id }
    }

    var body: some View {
        let isEmpty = store.favorites.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            if !isEmpty {
                TileGrid(metrics: metrics) {
                    ForEach(slots) { slot in
                        switch slot {
                        case .favorite(let favorite):
                            FavoriteTile(favorite: favorite)
                        case .dropSlot:
                            TileDropSlot()
                        }
                    }
                }
                .onSidebarFrame { drag.favoritesFrame = $0 }
                // Links dragged in from a web page or Safari's address bar.
                .onDrop(of: [.url], isTargeted: nil) { providers, location in
                    let index = metrics.slot(at: location, count: store.favorites.count)
                    return loadDroppedURL(from: providers) { url in
                        store.addBookmark(url: url, to: .favorites, at: index)
                    }
                }
                if let renamed {
                    FavoriteRenameRow(favorite: renamed)
                        .padding(.top, 6)
                }
            } else if drag.isActive {
                FavoritesDropArea(isTargeted: isDropTarget)
                    .frame(height: max(metrics.tile, TileGridMetrics.minimumTile))
                    .onSidebarFrame { drag.favoritesFrame = $0 }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            width = newWidth
            drag.favoritesMetrics = TileGridMetrics(width: newWidth)
        }
        .padding(.bottom, isEmpty && !drag.isActive ? 0 : 8)
    }
}

/// How the favorites' grid is laid out at a given width: square tiles, about four to a row at the
/// sidebar's usual width, more wrapping onto new rows. The cells don't move during a drag, so the
/// slot under the pointer is simply the cell it's in.
struct TileGridMetrics: Equatable {
    static let minimumTile: CGFloat = 50
    static let spacing: CGFloat = 6

    var width: CGFloat

    var columns: Int { max(2, Int((width + Self.spacing) / (Self.minimumTile + Self.spacing))) }
    var tile: CGFloat { max(0, (width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)) }
    var pitch: CGFloat { tile + Self.spacing }

    func origin(of index: Int) -> CGPoint {
        CGPoint(x: CGFloat(index % columns) * pitch, y: CGFloat(index / columns) * pitch)
    }

    func height(for count: Int) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return rows == 0 ? 0 : CGFloat(rows) * pitch - Self.spacing
    }

    /// The slot for a point in the grid's coordinates: the cell it's in, from 0 to `count` (past the
    /// last tile is the end).
    func slot(at point: CGPoint, count: Int) -> Int {
        guard pitch > 0 else { return max(count, 0) }
        let column = min(max(Int((point.x / pitch).rounded(.down)), 0), columns - 1)
        let row = max(Int((point.y / pitch).rounded(.down)), 0)
        return min(row * columns + column, max(count, 0))
    }
}

/// Places tiles in the cells of `TileGridMetrics`. A layout rather than a grid view, so the cells are
/// exactly where the drag computes them, and tiles moving between rows animate. The cells follow the
/// width the grid is given; `metrics` (the width last measured) only stands in when none is.
private struct TileGrid: Layout {
    let metrics: TileGridMetrics

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grid = proposal.width.map { TileGridMetrics(width: $0) } ?? metrics
        return CGSize(width: grid.width, height: grid.height(for: subviews.count))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = TileGridMetrics(width: bounds.width)
        let size = ProposedViewSize(width: metrics.tile, height: metrics.tile)
        for (index, subview) in subviews.enumerated() {
            let origin = metrics.origin(of: index)
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: size)
        }
    }
}

/// A favorite's tile: its site's icon. Its tab is like a pinned item's, with #25's rules: the tile
/// shows a soft tint while its tab is open in this window and a highlight while that tab is active.
/// There's no room for a "−": a middle click or Close Tab in its menu closes the tab.
struct FavoriteTile: View {
    static let cornerRadius: CGFloat = 9
    static let iconSize: CGFloat = 20

    let favorite: Bookmark

    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarDrag.self) private var drag
    @Environment(SidebarRows.self) private var rows
    @State private var hovering = false
    @State private var frame = CGRect.zero
    /// Whether the press in progress opens the favorite when the button goes up (see
    /// `TabStore.pressBookmark`). Every press sets it.
    @State private var opensOnRelease = false

    private var isRenaming: Bool { store.renaming == .bookmark(favorite.id) }
    private var isSlot: Bool { drag.isSlot(favorite: favorite) }

    private func pressBegan(at point: CGPoint) -> Bool {
        opensOnRelease = false
        guard !isRenaming else { return false }
        opensOnRelease = store.pressBookmark(favorite, command: NSEvent.modifierFlags.contains(.command))
        return true
    }

    private func released() {
        guard opensOnRelease, !isRenaming else { return }
        opensOnRelease = false
        store.open(favorite, inNewTab: NSEvent.modifierFlags.contains(.command))
    }

    private func fill(isOpen: Bool, isActive: Bool) -> Color {
        if isActive {
            return Color.accentColor.opacity(0.24)
        }
        if isOpen {
            return Color.accentColor.opacity(hovering && !drag.isActive ? 0.17 : 0.12)
        }
        return Color.primary.opacity(hovering && !drag.isActive ? 0.09 : 0.05)
    }

    var body: some View {
        let openTab = store.openTab(for: favorite)
        let isActive = openTab?.active == true
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        FaviconView(iconURL: favorite.faviconURL, pageURL: favorite.url, size: Self.iconSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(fill(isOpen: openTab != nil, isActive: isActive)))
            .overlay {
                if isActive {
                    shape.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                }
            }
            .opacity(isSlot ? 0 : 1)
            .overlay {
                if isSlot {
                    TileDropSlot()
                }
            }
            .background(MouseTracking(onHover: { hovering = $0 }))
            .contentShape(shape)
            // Like a pinned row: an open favorite switches to its tab on mouse-down, a closed one opens
            // on mouse-up, so a press that turns into a drag doesn't open it.
            .sidebarRowGesture(
                .favorite(favorite),
                drag: drag,
                store: store,
                settings: settings,
                rowTop: frame.minY,
                rowLeft: frame.minX,
                dragEnabled: !isRenaming,
                onPress: pressBegan(at:),
                onClick: released
            )
            .onSidebarFrame { frame = $0 }
            // Where the tile is, so a middle click on it can be found (SidebarPanel.sendEvent).
            .onWindowFrame { rows.setFrame($0, forBookmark: favorite.id) }
            .onDisappear { rows.removeBookmark(favorite.id) }
            .contextMenu { BookmarkMenu(bookmark: favorite, isFavorite: true, isOpen: openTab != nil) }
            .help(favorite.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(favorite.title)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { store.open(favorite) }
    }
}

/// The open cell where a dragged tile, row or tab will land among the favorites.
private struct TileDropSlot: View {
    var body: some View {
        RoundedRectangle(cornerRadius: FavoriteTile.cornerRadius, style: .continuous)
            .fill(Color.accentColor.opacity(0.1))
            .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    }
}

/// Where the favorites' grid would be, shown during a drag while there are none.
private struct FavoritesDropArea: View {
    let isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: FavoriteTile.cornerRadius, style: .continuous)
            .fill(Color.accentColor.opacity(isTargeted ? 0.12 : 0.04))
            .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.7 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .overlay {
                Label("Favorites", systemImage: "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }
}

/// Renaming a favorite. A tile has no room for its name, so the name is edited in a row under the grid.
private struct FavoriteRenameRow: View {
    let favorite: Bookmark
    @Environment(TabStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            FaviconView(iconURL: favorite.faviconURL, pageURL: favorite.url)
            RenameField(text: favorite.title, onCommit: store.commitRename, onCancel: store.cancelRename)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: SidebarDrag.rowHeight)
        .background(RowBackground(isActive: true, isHovering: false))
    }
}
