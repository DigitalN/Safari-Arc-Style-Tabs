import CoreGraphics

// Where the profile buttons go in the sidebar's bottom bar, and when they turn into a dropdown (#39).
// Kept apart from SwiftUI so the checks can run it (Tests/ProfileChecks).
//
// The buttons are centred in the sidebar, whatever the bar holds on its left and right. So the room they
// get is the same on both sides: the bar's width, less the wider of the two side items (and a gap) on each
// side. When the buttons don't fit in that room, one dropdown takes their place, centred in the same room.

nonisolated enum ProfileBarLayout {
    /// A profile button, and the space between two.
    static let buttonWidth: CGFloat = 26
    static let buttonSpacing: CGFloat = 2
    /// The buttons at the bar's ends: Closed Tabs on the left (while cleanup is on), + on the right.
    static let sideButtonWidth: CGFloat = 28
    /// The bar's own inset from the sidebar's edges, on each side.
    static let barInset: CGFloat = 8
    /// Between a side item and the buttons, at the least.
    static let gap: CGFloat = 4

    enum Middle: Equatable {
        /// One profile, or none: only the side buttons show.
        case nothing
        case buttons
        /// One dropdown, at most `maxWidth` wide.
        case dropdown(maxWidth: CGFloat)
    }

    /// The bar's width inside its insets, for a sidebar `sidebarWidth` wide (Settings → Width).
    static func barWidth(sidebarWidth: CGFloat) -> CGFloat {
        max(0, sidebarWidth - 2 * barInset)
    }

    /// The room for the middle, centred in a bar `barWidth` wide whose left and right items are `leading`
    /// and `trailing` wide: the same on both sides, as much as the wider of the two leaves.
    static func room(barWidth: CGFloat, leading: CGFloat, trailing: CGFloat) -> CGFloat {
        let side = max(leading, trailing)
        return max(0, barWidth - 2 * (side > 0 ? side + gap : 0))
    }

    /// How wide `count` buttons are, side by side.
    static func buttonsWidth(count: Int) -> CGFloat {
        count > 0 ? CGFloat(count) * buttonWidth + CGFloat(count - 1) * buttonSpacing : 0
    }

    /// How many buttons fit in `room`.
    static func buttonsFitting(in room: CGFloat) -> Int {
        guard room >= buttonWidth else { return 0 }
        return Int(((room + buttonSpacing) / (buttonWidth + buttonSpacing)).rounded(.down))
    }

    /// What the middle shows for `profileCount` profiles.
    static func middle(profileCount: Int, barWidth: CGFloat, leading: CGFloat, trailing: CGFloat) -> Middle {
        guard profileCount > 1 else { return .nothing }
        let room = room(barWidth: barWidth, leading: leading, trailing: trailing)
        return profileCount <= buttonsFitting(in: room) ? .buttons : .dropdown(maxWidth: room)
    }

    /// Where something `width` wide goes when centred in the bar, from its left edge: its left and right
    /// ends. The space from the bar's left edge to `minX` and from `maxX` to its right edge is the same.
    static func centred(width: CGFloat, barWidth: CGFloat) -> (minX: CGFloat, maxX: CGFloat) {
        let minX = (barWidth - width) / 2
        return (minX, minX + width)
    }
}
