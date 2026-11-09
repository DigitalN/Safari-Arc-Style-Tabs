import SwiftUI

/// The tabs cleanup closed, newest first, shown in place of the sidebar's sections while it's open (the
/// button at the bottom left opens it). Clicking one reopens it and goes back to the tabs.
struct ClosedTabsList: View {
    @Binding var isShown: Bool
    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let closed = store.cleanup.closedTabs
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
                SectionHeader(title: "Closed Tabs", detail: closed.isEmpty ? nil : "\(closed.count)") {
                    SidebarIconButton(systemImage: "xmark", help: "Back to Tabs", size: 9) {
                        isShown = false
                    }
                }

                if closed.isEmpty {
                    Text("Tabs you haven't looked at for \(settings.unviewedTabInterval.label) are closed and listed here, so you can reopen them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // The ages ("5m", "3h") move on by themselves.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        LazyVStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
                            ForEach(closed) { tab in
                                ClosedTabRow(tab: tab, now: context.date) {
                                    store.reopen(tab)
                                    isShown = false
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ClosedTabRow: View {
    let tab: ClosedTab
    let now: Date
    let onReopen: () -> Void

    @Environment(TabStore.self) private var store
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            FaviconView(iconURL: tab.faviconURL, pageURL: tab.url)
            Text(tab.shownTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(TabCleanup.age(of: tab.closedAt, now: now))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: SidebarDrag.rowHeight)
        .background(RowBackground(isActive: false, isHovering: hovering))
        .background(MouseTracking(onHover: { hovering = $0 }))
        .contentShape(Rectangle())
        .onTapGesture(perform: onReopen)
        .contextMenu {
            Button("Reopen Tab", action: onReopen)
            Button("Copy Link") { store.copyLink(tab.url) }
            Divider()
            Button("Remove from List") { store.cleanup.remove(tab.id) }
        }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onReopen() }
    }

    private var tooltip: String {
        var lines = [tab.shownTitle]
        if tab.customName != nil, tab.title != tab.shownTitle {
            lines.append(tab.title)
        }
        lines.append(tab.url)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        lines.append("Closed " + formatter.localizedString(for: tab.closedAt, relativeTo: now))
        return lines.joined(separator: "\n")
    }
}

extension View {
    /// This view, or `other` in its place while `condition` holds. This view is taken out rather than
    /// covered, so its rows are gone too and a middle click can't find a tab under `other` (SidebarRows).
    @ViewBuilder func replaced<Other: View>(by other: Other, when condition: Bool) -> some View {
        if condition {
            other
        } else {
            self
        }
    }
}
