import CoreGraphics
import Foundation
import Observation

// Which tab or bookmark row is under a point. SwiftUI's own hit testing can't be asked from SidebarPanel: on
// macOS 26 it answers with an internal container view for rows built with views embedded in
// SwiftUI, never the row (#21), so a middle click (which SwiftUI has no gesture for) wouldn't
// reach the row. The rows report where they are instead, and the panel looks the point up.

/// Frames of rows, and the part of the list that's showing.
nonisolated struct RowHitTester<ID: Hashable> {
    var frames: [ID: CGRect] = [:]
    /// The visible part of the scrolling list. A row scrolled out of it still has a frame, and
    /// the point might be on something else there (the address bar above the list).
    var viewport = CGRect.zero

    func row(at point: CGPoint) -> ID? {
        guard viewport.contains(point) else { return nil }
        return frames.first { $0.value.contains(point) }?.key
    }
}

/// Where the sidebar's tab and bookmark rows are, in the window's coordinates (origin at the top
/// left, like SwiftUI's `.global`).
@Observable
final class SidebarRows {
    @ObservationIgnored private var tester = RowHitTester<TabKey>()
    @ObservationIgnored private var bookmarkTester = RowHitTester<UUID>()

    var viewport: CGRect {
        get { tester.viewport }
        set {
            tester.viewport = newValue
            bookmarkTester.viewport = newValue
        }
    }

    func setFrame(_ frame: CGRect, for key: TabKey) {
        if tester.frames[key] != frame {
            tester.frames[key] = frame
        }
    }

    func remove(_ key: TabKey) {
        tester.frames[key] = nil
    }

    func tab(at point: CGPoint) -> TabKey? {
        tester.row(at: point)
    }

    func setFrame(_ frame: CGRect, forBookmark id: UUID) {
        if bookmarkTester.frames[id] != frame {
            bookmarkTester.frames[id] = frame
        }
    }

    func removeBookmark(_ id: UUID) {
        bookmarkTester.frames[id] = nil
    }

    func bookmark(at point: CGPoint) -> UUID? {
        bookmarkTester.row(at: point)
    }
}
