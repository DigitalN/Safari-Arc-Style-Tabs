import CoreGraphics

// The favorites' grid (#34), apart from SwiftUI so Tests/TileGridChecks can run it at every width SwiftUI
// can propose. Laid out by FavoritesSection's TileGrid.

/// How the favorites' grid is laid out at a given width: square tiles, about four to a row at the
/// sidebar's usual width, more wrapping onto new rows. The cells don't move during a drag, so the
/// slot under the pointer is simply the cell it's in.
nonisolated struct TileGridMetrics: Equatable {
    static let minimumTile: CGFloat = 50
    static let spacing: CGFloat = 6

    var width: CGFloat

    /// SwiftUI measures with an infinite or zero width at times. Turning infinity into a count crashed
    /// Side Tabs at launch, so a width that isn't a real, positive number gets the fewest columns.
    var columns: Int {
        guard width.isFinite, width > 0 else { return 2 }
        return max(2, Int((width + Self.spacing) / (Self.minimumTile + Self.spacing)))
    }
    var tile: CGFloat { max(0, (width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)) }
    var pitch: CGFloat { tile + Self.spacing }

    /// The metrics for a width SwiftUI proposes. An unspecified or infinite width (SwiftUI asking for the
    /// grid's ideal or largest size) gets `measured`, the width last measured.
    static func proposed(_ width: CGFloat?, measured: TileGridMetrics) -> TileGridMetrics {
        guard let width, width.isFinite else { return measured }
        return TileGridMetrics(width: width)
    }

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
        guard pitch > 0, pitch.isFinite, point.x.isFinite, point.y.isFinite else { return max(count, 0) }
        let column = min(max(Int((point.x / pitch).rounded(.down)), 0), columns - 1)
        let row = max(Int((point.y / pitch).rounded(.down)), 0)
        return min(row * columns + column, max(count, 0))
    }
}
