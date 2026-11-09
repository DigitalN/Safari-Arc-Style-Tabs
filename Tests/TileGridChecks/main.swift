import CoreGraphics
import Foundation

// How the favorites' grid lays out its tiles (SideTabs/TileGridMetrics.swift), at the widths SwiftUI
// proposes, including the infinite one that crashed Side Tabs at launch. No SwiftUI involved.

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

let measured = TileGridMetrics(width: 260)

// The widths SwiftUI can propose to a layout's sizeThatFits.
check(TileGridMetrics.proposed(.infinity, measured: measured) == measured, "an infinite proposal uses the width last measured")
check(TileGridMetrics.proposed(nil, measured: measured) == measured, "so does an unspecified one")
check(TileGridMetrics.proposed(.nan, measured: measured) == measured, "and one that isn't a number")
check(TileGridMetrics.proposed(200, measured: measured).width == 200, "a real proposal is taken as it is")
check(TileGridMetrics.proposed(0, measured: measured).width == 0, "zero too: it's a real width")

// Widths that aren't positive, finite numbers never reach an Int conversion.
for width in [CGFloat.infinity, -CGFloat.infinity, .nan, 0, -10] {
    let metrics = TileGridMetrics(width: width)
    check(metrics.columns == 2, "a width of \(width) gets the fewest columns")
    check(metrics.slot(at: CGPoint(x: 30, y: 30), count: 9) >= 0, "and a slot, without crashing")
}
check(TileGridMetrics(width: 0).height(for: 9).isFinite, "a zero width still gives a finite height")
check(measured.slot(at: CGPoint(x: CGFloat.nan, y: 10), count: 9) == 9, "a point that isn't a number is the end")

// The issue's sizes: about four tiles to a row at the usual width.
check(TileGridMetrics(width: 260).columns == 4, "4 columns at the default 260 pt")
check(TileGridMetrics(width: 180).columns == 3, "3 at 180 pt")
check(TileGridMetrics(width: 420).columns == 7, "7 at 420 pt")
let grid = TileGridMetrics(width: 260)
check(abs(grid.tile * 4 + TileGridMetrics.spacing * 3 - 260) < 0.001, "the tiles and gaps fill the width")
check(grid.height(for: 0) == 0, "no favorites take no room")
check(grid.height(for: 5) == grid.pitch * 2 - TileGridMetrics.spacing, "five favorites take two rows")
check(grid.slot(at: CGPoint(x: grid.pitch * 1.5, y: grid.pitch * 0.5), count: 9) == 1, "the slot is the cell under the point")
check(grid.slot(at: CGPoint(x: 5, y: grid.pitch * 9), count: 9) == 9, "below the last row is the end")

if failures > 0 {
    print("\(failures) tile grid checks failed")
    exit(1)
}
print("tile grid checks passed")
