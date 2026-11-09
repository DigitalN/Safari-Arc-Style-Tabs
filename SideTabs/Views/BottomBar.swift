import SwiftUI

/// The bar along the bottom of the sidebar. On the left, where Arc keeps its Archive, is the button
/// for the tabs cleanup closed (while cleanup is on). The middle and the right are kept for the
/// profile buttons and a + to come. The bar takes no room while it has nothing to show.
struct BottomBar: View {
    @Binding var showsClosedTabs: Bool
    @Environment(AppSettings.self) private var settings

    private var hasContent: Bool { settings.closesUnviewedTabs }

    var body: some View {
        if hasContent {
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
    }

    @ViewBuilder private var leading: some View {
        if settings.closesUnviewedTabs {
            ClosedTabsButton(isOn: $showsClosedTabs)
        }
    }

    /// Where the profile buttons go.
    private var middle: some View { EmptyView() }

    /// Where the + for a new profile goes.
    private var trailing: some View { EmptyView() }
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
