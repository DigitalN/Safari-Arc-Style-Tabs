import AppKit
import SwiftUI

/// The bar along the bottom of the sidebar. On the left, where Arc keeps its Archive, is the button
/// for the tabs cleanup closed (while cleanup is on). In the middle, one button per Safari profile,
/// in Safari's order (#33); on the right, a + for a new profile. The + always shows, so the bar is
/// always there; with a single profile, only the + shows.
///
/// The profile buttons are centred in the sidebar whatever the ends hold (#39), and when they don't
/// fit in the same room on both sides, one dropdown takes their place (ProfileBarLayout).
struct BottomBar: View {
    @Binding var showsClosedTabs: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(SafariProfiles.self) private var profiles
    /// The bar's width inside its insets, and its two ends', as last laid out.
    @State private var barWidth: CGFloat?
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth = ProfileBarLayout.sideButtonWidth

    private var layout: ProfileBarLayout.Middle {
        ProfileBarLayout.middle(
            profileCount: profiles.profiles.count,
            barWidth: barWidth ?? ProfileBarLayout.barWidth(sidebarWidth: settings.width),
            leading: leadingWidth,
            trailing: trailingWidth
        )
    }

    var body: some View {
        // The ends at the edges, and the middle centred over them in the whole bar, so an empty end
        // (cleanup off) can't pull it to one side.
        ZStack {
            HStack(spacing: 0) {
                HStack(spacing: 4) { leading }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
                Spacer(minLength: 0)
                HStack(spacing: 4) { trailing }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
            }
            middle
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .padding(.horizontal, ProfileBarLayout.barInset)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var leading: some View {
        if settings.closesUnviewedTabs {
            ClosedTabsButton(isOn: $showsClosedTabs)
        }
    }

    /// The profile buttons, or the dropdown when they don't fit.
    @ViewBuilder private var middle: some View {
        switch layout {
        case .nothing:
            EmptyView()
        case .buttons:
            ProfileButtons()
        case .dropdown(let maxWidth):
            ProfileDropdown()
                .frame(maxWidth: maxWidth)
        }
    }

    private var trailing: some View {
        BarButton(systemImage: "plus", help: "New Profile") {
            profiles.newProfile()
        }
    }
}

/// One button per profile. The front window's profile is highlighted and the others dimmed; in a
/// private window, none is highlighted.
private struct ProfileButtons: View {
    @Environment(SafariProfiles.self) private var profiles

    var body: some View {
        HStack(spacing: ProfileBarLayout.buttonSpacing) {
            ForEach(profiles.profiles) { profile in
                ProfileButton(profile: profile, isCurrent: profile.id == profiles.highlightedID) {
                    profiles.select(profile)
                }
            }
        }
    }
}

/// A profile's SF Symbol in one neutral tint, or its first letter while the symbol hasn't been seen.
/// Hovering shows its name (names aren't unique, so two can show the same one). It switches on
/// mouse-down, like every other click in the sidebar.
private struct ProfileButton: View {
    let profile: SafariProfile
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        ProfileIcon(profile: profile)
            .frame(width: ProfileBarLayout.buttonWidth, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isCurrent ? 0.12 : hovering ? 0.055 : 0))
            )
            .foregroundStyle(isCurrent ? .primary : .secondary)
            .opacity(isCurrent || hovering ? 1 : 0.65)
            .contentShape(Rectangle())
            .background(MouseTracking(onHover: { hovering = $0 }))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                    }
                    .onEnded { _ in pressed = false }
            )
            .help(profile.name)
            .accessibilityElement()
            .accessibilityLabel(profile.name)
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
    }

}

/// A profile's SF Symbol, or its first letter while the symbol hasn't been seen (or doesn't exist on
/// this macOS). Without a profile (a private window), a neutral symbol.
private struct ProfileIcon: View {
    let profile: SafariProfile?

    var body: some View {
        if let profile {
            if let symbol = profile.symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
            } else {
                Text(profile.initial)
                    .font(.system(size: 12, weight: .semibold))
            }
        } else {
            Image(systemName: ProfileMenuView.noProfileSymbol)
                .font(.system(size: 12, weight: .medium))
        }
    }
}

/// In place of the buttons when they don't fit: the current profile's symbol, its name (shortened to
/// fit) and a chevron, which opens a menu of every profile. In a private window, where no profile is
/// current, a neutral symbol and "Profiles". It opens on mouse-down, like the buttons switch.
private struct ProfileDropdown: View {
    @Environment(SafariProfiles.self) private var profiles
    @State private var hovering = false

    private var current: SafariProfile? {
        profiles.profiles.first { $0.id == profiles.highlightedID }
    }

    var body: some View {
        let name = current?.name ?? "Profiles"
        HStack(spacing: 5) {
            ProfileIcon(profile: current)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.1 : 0.06))
        )
        .background(MouseTracking(onHover: { hovering = $0 }))
        // The view on top gets the click; it reads as the pop-up button.
        .accessibilityHidden(true)
        .overlay(ProfileMenuTarget(profiles: profiles.profiles, currentID: profiles.highlightedID, name: current?.name) { profile in
            profiles.select(profile)
        })
    }
}

/// The clickable part of the dropdown: an AppKit view over its label, so the menu opens on mouse-down
/// and the panel can tell the click is the dropdown's (see OpensMenuOnMouseDown).
private struct ProfileMenuTarget: NSViewRepresentable {
    let profiles: [SafariProfile]
    let currentID: UUID?
    let name: String?
    /// Switches to the profile chosen; says whether that started a switch.
    let select: (SafariProfile) -> Bool

    func makeNSView(context: Context) -> ProfileMenuView {
        let view = ProfileMenuView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ProfileMenuView, context: Context) {
        view.profiles = profiles
        view.currentID = currentID
        view.name = name
        view.select = select
        view.toolTip = name ?? "Profiles"
    }
}

/// A small button in the bar.
private struct BarButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: ProfileBarLayout.sideButtonWidth, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.055 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(MouseTracking(onHover: { hovering = $0 }))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Shows or hides the list of tabs cleanup closed (ClosedTabsList).
private struct ClosedTabsButton: View {
    @Binding var isOn: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: "archivebox")
                .font(.system(size: 13, weight: .medium))
                .frame(width: ProfileBarLayout.sideButtonWidth, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isOn ? 0.12 : hovering ? 0.055 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? .primary : .secondary)
        .background(MouseTracking(onHover: { hovering = $0 }))
        .help(isOn ? "Back to Tabs" : "Closed Tabs")
        // Gone when cleanup is turned off, and the list with it, so turning it back on doesn't
        // bring the list back by itself.
        .onDisappear { isOn = false }
        .accessibilityLabel("Closed Tabs")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
