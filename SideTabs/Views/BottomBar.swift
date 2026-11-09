import AppKit
import SwiftUI

/// The bar along the bottom of the sidebar. On the left, where Arc keeps its Archive, is the button
/// for the tabs cleanup closed (while cleanup is on). In the middle, one button per Safari profile,
/// in Safari's order (#33); on the right, a + for a new profile. The + always shows, so the bar is
/// always there; with a single profile, only the + shows.
struct BottomBar: View {
    @Binding var showsClosedTabs: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(SafariProfiles.self) private var profiles

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            middle
            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var leading: some View {
        if settings.closesUnviewedTabs {
            ClosedTabsButton(isOn: $showsClosedTabs)
        }
    }

    /// The profile buttons, centred. With more than fit, they scroll.
    @ViewBuilder private var middle: some View {
        if profiles.showsButtons {
            ViewThatFits(in: .horizontal) {
                ProfileButtons()
                ScrollView(.horizontal) {
                    ProfileButtons()
                }
                .scrollIndicators(.never)
            }
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
        HStack(spacing: 2) {
            ForEach(profiles.profiles) { profile in
                ProfileButton(profile: profile, isCurrent: profile.id == profiles.highlightedID) {
                    profiles.select(profile)
                }
            }
        }
        .padding(.horizontal, 4)
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
        icon
            .frame(width: 26, height: 24)
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

    @ViewBuilder private var icon: some View {
        if let symbol = profile.symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
        } else {
            Text(profile.initial)
                .font(.system(size: 12, weight: .semibold))
        }
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
                .frame(width: 28, height: 24)
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
                .frame(width: 28, height: 24)
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
