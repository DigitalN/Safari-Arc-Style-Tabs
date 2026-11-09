import SwiftUI

/// What the sidebar shows in place of its sections while the front window's profile has Side Tabs
/// off (#33): one row that takes the user to where they turn it on. Otherwise the sections would list
/// another window's tabs. The user ticks the box; Side Tabs never does (a scripted tick makes Safari
/// ask for Touch ID). Once that profile's copy starts, the row goes away by itself.
struct TurnOnSideTabsRow: View {
    @Environment(SafariProfiles.self) private var profiles
    @State private var hovering = false

    var body: some View {
        Button {
            profiles.turnOnSideTabs()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Turn on Side Tabs for this profile")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RowBackground(isActive: false, isHovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MouseTracking(onHover: { hovering = $0 }))
        .help("Opens this profile's extensions in Safari Settings")
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
