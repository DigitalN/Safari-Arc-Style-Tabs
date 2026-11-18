import CoreGraphics

/// Whether an empty Favorites list shows its drop area during a drag (#76 hand test). With no favorites, Favorites takes
/// no room, and a drop area that appeared as soon as a drag began pushed everything below it down under the pointer.
/// So it stays hidden until the pointer reaches Pinned's header, which is where Favorites would sit, and then stays
/// until the drag ends: at most one shift per drag, and only when heading for the top. A folder, which Favorites
/// refuses, never shows it. Kept apart from SwiftUI so Tests/StoreChecks can check it; SidebarDrag keeps one.
struct FavoritesReveal: Equatable {
    /// Whether the drop area shows. It only matters while there are no favorites: with some, the grid is there.
    private(set) var isShown = false

    /// The pointer moved during a drag, to `pointerY`; `headerBottom` is the bottom of Pinned's header, in the same
    /// (sidebar content) coordinates. Says whether the drop area has just appeared.
    @discardableResult
    mutating func pointerMoved(toY pointerY: CGFloat, headerBottom: CGFloat, hasFavorites: Bool, draggingFolder: Bool) -> Bool {
        guard !isShown, !hasFavorites, !draggingFolder, pointerY.isFinite, pointerY < headerBottom else { return false }
        isShown = true
        return true
    }

    /// The drag ended or was cancelled.
    mutating func reset() {
        isShown = false
    }
}
