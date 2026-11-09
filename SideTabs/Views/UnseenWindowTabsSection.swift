import SwiftUI

/// In place of Tabs while the docked window is one its profile's copy can't see (#41): a short note, then
/// the window's tabs as its tab bar shows them (UnseenWindowTabs). Letter tiles stand in for icons, the
/// selected tab is highlighted, a press switches on mouse-down, and a tab closes where Safari offers that.
struct UnseenWindowTabsSection: View {
    let isPrivate: Bool
    @Environment(SafariProfiles.self) private var profiles

    var body: some View {
        let unseen = profiles.unseenTabs
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Tabs", detail: unseen.tabs.isEmpty ? nil : "\(unseen.tabs.count)") {
                EmptyView()
            }
            UnseenWindowNote(isPrivate: isPrivate)
                .padding(.bottom, 4)
            ForEach(unseen.tabs) { tab in
                UnseenTabRow(tab: tab, isSelected: tab.position == unseen.selected, canClose: unseen.canClose)
            }
        }
    }
}

/// Why this window's tabs look different, and the ways out, from what the live test found (#41): Safari
/// doesn't give the extension a profile's windows that were open when it reloaded; windows opened since are
/// shared, and so are the hidden ones once Safari has quit and reopened them. Private windows don't come back
/// with Safari, so for them only a new window helps.
private struct UnseenWindowNote: View {
    let isPrivate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isPrivate ? "Safari isn't sharing this private window" : "Safari isn't sharing this window")
                .font(.system(size: 11, weight: .semibold))
            Text(isPrivate
                 ? "It was open when Side Tabs was updated, so its tabs are read from the tab bar. New private windows show in full."
                 : "It was open when Side Tabs was updated, so its tabs are read from the tab bar, and favorites and pinned items open in a window Safari shares. New windows show in full, and so does this one after you quit and reopen Safari (History → Reopen All Windows from Last Session).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 2)
    }
}

/// One tab of the window: a letter tile, its title, and a close button on hover where Safari offers one.
/// Switches on mouse-down, like the sidebar's other rows; the close button closes instead.
private struct UnseenTabRow: View {
    let tab: UnseenWindowTabs.Tab
    let isSelected: Bool
    let canClose: Bool
    @Environment(SafariProfiles.self) private var profiles
    @State private var hovering = false
    @State private var pressed = false
    @State private var width: CGFloat = 0

    private static let closeWidth: CGFloat = 24

    var body: some View {
        let title = tab.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        HStack(spacing: 8) {
            LetterTile(host: title)
                .frame(width: 16, height: 16)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if canClose && hovering {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RowBackground(isActive: isSelected, isHovering: hovering))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(MouseTracking(onHover: { hovering = $0 }))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !pressed else { return }
                    pressed = true
                    if canClose && hovering && value.startLocation.x >= width - Self.closeWidth {
                        profiles.unseenTabs.close(tab)
                    } else {
                        profiles.unseenTabs.select(tab)
                    }
                }
                .onEnded { _ in pressed = false }
        )
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { profiles.unseenTabs.select(tab) }
        .accessibilityAction(named: "Close Tab") {
            if canClose { profiles.unseenTabs.close(tab) }
        }
    }
}
