import SwiftUI

/// A row in the Pinned list (#34): a pinned item, with #25's rules for its tab.
struct BookmarkRow: View {
    let bookmark: Bookmark

    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarDrag.self) private var drag
    @Environment(SidebarRows.self) private var rows
    @State private var hovering = false
    @State private var rowTop: CGFloat = 0
    /// Whether the press in progress opens the bookmark when the button goes up, because it didn't
    /// switch to the bookmark's tab on mouse-down. Every press the row sees sets it, so a cancelled
    /// or declined one leaves nothing behind for the next to depend on.
    @State private var opensOnRelease = false
    /// Where the "−" is, in sidebar coordinates (the space the row's gesture reports presses in).
    /// Presses on it belong to the button, not the row. Only trusted while the button is showing.
    @State private var closeFrame = CGRect.zero

    private var isRenaming: Bool { store.renaming == .bookmark(bookmark.id) }
    private var isSlot: Bool { drag.isSlot(pinned: bookmark) }

    /// The first event of a press, with where it landed (sidebar coordinates). Says whether the
    /// row took it.
    private func pressBegan(at point: CGPoint) -> Bool {
        opensOnRelease = false
        guard !isRenaming else { return false }
        if store.openTab(for: bookmark) != nil && closeFrame.containsCircle(point) {
            return false
        }
        opensOnRelease = store.pressBookmark(bookmark, command: NSEvent.modifierFlags.contains(.command))
        return true
    }

    /// The button went up without the press having turned into a drag.
    private func released() {
        guard opensOnRelease, !isRenaming else { return }
        opensOnRelease = false
        store.open(bookmark, inNewTab: NSEvent.modifierFlags.contains(.command))
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

            if openTab != nil && !isRenaming {
                // Closes the bookmark's tab, like a tab row's close button, and puts the bookmark
                // back to closed.
                SidebarIconButton(systemImage: "minus", help: "Close Tab", size: 10) {
                    store.closeBookmarkTab(bookmark.id)
                }
                .onSidebarFrame { closeFrame = $0 }
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 8)
        // The "−" lines up with the close buttons of the tab rows.
        .padding(.trailing, openTab != nil && !isRenaming ? 4 : 8)
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
        // A bookmark whose tab is open is a tab switch, so it switches on mouse-down like the tab
        // rows. One that isn't open opens a tab on mouse-up instead: on mouse-down, starting a drag
        // to reorder would create a tab, and a press that turned into a drag never opens one.
        .sidebarRowGesture(
            .pinned(bookmark),
            drag: drag,
            store: store,
            settings: settings,
            rowTop: rowTop,
            dragEnabled: !isRenaming,
            onPress: pressBegan(at:),
            onClick: released
        )
        .accessibilityAction { openFromAccessibility() }
        .onSidebarTop { rowTop = $0 }
        // Where the row is, so a middle click on it can be found (SidebarPanel.sendEvent).
        .onWindowFrame { rows.setFrame($0, forBookmark: bookmark.id) }
        .onDisappear { rows.removeBookmark(bookmark.id) }
        .contextMenu { BookmarkMenu(bookmark: bookmark, isFavorite: false, isOpen: openTab != nil) }
        .help("\(bookmark.title)\n\(bookmark.url)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(openTab?.active == true ? [.isButton, .isSelected] : .isButton)
    }
}

/// The menu of a favorite's tile and of a pinned row.
struct BookmarkMenu: View {
    let bookmark: Bookmark
    let isFavorite: Bool
    /// Whether its tab is open in the window the sidebar shows.
    let isOpen: Bool
    @Environment(TabStore.self) private var store

    var body: some View {
        Button("Open") { store.open(bookmark) }
        Button("Open in New Tab") { store.open(bookmark, inNewTab: true) }
        Divider()
        Button("Rename…") { store.beginRename(.bookmark(bookmark.id)) }
        Button("Replace with Current Page") { store.replaceBookmarkWithCurrentPage(bookmark) }
        Button("Copy Link") { store.copyLink(bookmark.url) }
        Divider()
        if isFavorite {
            // A private window has no Pinned list to move it to.
            if let pinned = store.currentPinnedList {
                Button("Move to Pinned") { store.moveBookmark(bookmark.id, to: pinned, at: store.bookmarks(in: pinned).count) }
            }
        } else {
            Button("Move to Favorites") { store.moveBookmark(bookmark.id, to: .favorites, at: store.favorites.count) }
        }
        if isOpen {
            Button("Close Tab") { store.closeBookmarkTab(bookmark.id) }
        }
        Button(isFavorite ? "Remove from Favorites" : "Remove from Pinned") { store.removeBookmark(bookmark) }
    }
}
