import SwiftUI

struct BookmarkRow: View {
    let bookmark: Bookmark

    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarDrag.self) private var drag
    @State private var hovering = false
    @State private var rowTop: CGFloat = 0
    /// True while a press is in progress (see TabRow for why this is a gesture state).
    @GestureState private var pressInProgress = false
    /// Whether the press in progress already switched to the open tab. Every press sets it, so
    /// a cancelled one leaves nothing behind for the next to depend on.
    @State private var switchedOnPress = false

    private var isRenaming: Bool { store.renaming == .bookmark(bookmark.id) }
    private var isSlot: Bool { drag.isSlot(bookmark: bookmark) }

    private func pressBegan() {
        let inNewTab = NSEvent.modifierFlags.contains(.command)
        switchedOnPress = !isRenaming && !inNewTab && store.openTab(for: bookmark) != nil
        if switchedOnPress {
            store.open(bookmark)
        }
    }

    private func openFromAccessibility() {
        guard !isRenaming else { return }
        store.open(bookmark)
    }

    var body: some View {
        let openTab = store.openTab(for: bookmark)

        HStack(spacing: 8) {
            FaviconView(iconURL: bookmark.faviconURL, pageURL: bookmark.url)

            if isRenaming {
                RenameField(text: bookmark.title, onCommit: store.commitRename, onCancel: store.cancelRename)
            } else {
                Text(bookmark.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if openTab != nil {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 5, height: 5)
                    .padding(.trailing, 6)
                    .help("Open in this window")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: SidebarDrag.rowHeight)
        .background(RowBackground(isActive: openTab?.active == true, isHovering: hovering && !drag.isActive))
        .background(MouseTracking(onHover: { hovering = $0 }))
        .opacity(isSlot ? 0 : 1)
        .overlay {
            if isSlot {
                DropSlot()
            }
        }
        .contentShape(Rectangle())
        // A pinned site that's already open is a tab switch, so it switches on mouse-down like
        // the tab rows. One that isn't open opens a tab on mouse-up instead: on mouse-down, starting
        // a drag to reorder would create a tab.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($pressInProgress) { _, inProgress, _ in
                    guard !inProgress else { return }
                    inProgress = true
                    pressBegan()
                }
                .onEnded { value in
                    // Moving far enough to drag is the reorder gesture's, not a click.
                    guard !switchedOnPress, !isRenaming, hypot(value.translation.width, value.translation.height) < 4 else { return }
                    store.open(bookmark, inNewTab: NSEvent.modifierFlags.contains(.command))
                }
        )
        .accessibilityAction { openFromAccessibility() }
        .sidebarDraggable(
            .bookmark(bookmark),
            drag: drag,
            store: store,
            settings: settings,
            rowTop: rowTop,
            enabled: !isRenaming
        )
        .onSidebarTop { rowTop = $0 }
        .contextMenu {
            Button("Open") { store.open(bookmark) }
            Button("Open in New Tab") { store.open(bookmark, inNewTab: true) }
            Divider()
            Button("Rename…") { store.beginRename(.bookmark(bookmark.id)) }
            Button("Replace with Current Page") { store.replaceBookmarkWithCurrentPage(bookmark) }
            Button("Copy Link") { store.copyLink(bookmark.url) }
            Divider()
            Button("Remove Bookmark") { store.removeBookmark(bookmark) }
        }
        .help("\(bookmark.title)\n\(bookmark.url)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
