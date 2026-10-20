import SwiftUI

struct BookmarkRow: View {
    let bookmark: Bookmark
    var draggable = true

    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarDrag.self) private var drag
    @State private var hovering = false
    @State private var rowTop: CGFloat = 0

    private var isRenaming: Bool { store.renaming == .bookmark(bookmark.id) }
    private var isSlot: Bool { drag.isSlot(bookmark: bookmark) }

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

            if let openTab, let selection = store.currentWindow {
                if openTab.audible || openTab.muted {
                    SidebarIconButton(systemImage: openTab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                      help: openTab.muted ? "Unmute Tab" : "Mute Tab", size: 10) {
                        store.setMuted(!openTab.muted, tab: openTab, instance: selection.instance)
                    }
                }
                ZStack {
                    if settings.closeButtonMode == .always || hovering || openTab.active {
                        SidebarIconButton(systemImage: "xmark", help: "Close Tab", size: 9) {
                            store.close([openTab], instance: selection.instance)
                        }
                    } else {
                        Circle().fill(Color.secondary).frame(width: 5, height: 5).help("Open in this window")
                    }
                }.frame(width: 20, height: 20)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: SidebarDrag.rowHeight)
        .background(RowBackground(isActive: openTab?.active == true, isHovering: hovering && !drag.isActive, isSelected: store.selectedSidebarItems.contains(.bookmark(bookmark.id))))
        .background(MouseTracking(onHover: { hovering = $0 }, onMiddleClick: {
            if let openTab, let selection = store.currentWindow { store.close([openTab], instance: selection.instance) }
        }))
        .opacity(isSlot ? 0 : 1)
        .overlay {
            if isSlot {
                DropSlot()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            let extending = NSEvent.modifierFlags.contains(.shift)
            store.selectSidebarItem(.bookmark(bookmark.id), extending: extending)
            if extending { return }
            store.open(bookmark, inNewTab: NSEvent.modifierFlags.contains(.command))
        }
        .sidebarDraggable(
            .bookmark(bookmark),
            drag: drag,
            store: store,
            settings: settings,
            rowTop: rowTop,
            enabled: draggable && !isRenaming
        )
        .onSidebarTop { rowTop = $0 }
        .contextMenu {
            if store.selectedSidebarItems.contains(.bookmark(bookmark.id)) {
                BulkSelectionActions()
                Divider()
            }
            Button("Open") { store.open(bookmark) }
            Button("Open in New Tab") { store.open(bookmark, inNewTab: true) }
            if let openTab, let selection = store.currentWindow {
                Button("Reload Tab") { store.reload(openTab, instance: selection.instance) }
                Button("Close Tab") { store.close([openTab], instance: selection.instance) }
            }
            Divider()
            Button("Rename…") { store.beginRename(.bookmark(bookmark.id)) }
            Button("Replace with Current Page") { store.replaceBookmarkWithCurrentPage(bookmark) }
            if bookmark.spaceID != nil {
                Menu("Move to Folder") { FolderDestinations(item: .bookmark(bookmark.id)) }
                Button("Move Up") { store.reorderPinnedItem(.bookmark(bookmark.id), direction: -1) }
                Button("Move Down") { store.reorderPinnedItem(.bookmark(bookmark.id), direction: 1) }
            }
            Menu("Move To") {
                Button("Favorites (All Spaces)") { store.moveBookmarkToSpace(bookmark, spaceID: nil) }
                ForEach(store.spaces) { space in
                    Button(space.name) { store.moveBookmarkToSpace(bookmark, spaceID: space.id) }
                }
            }
            Button("Copy Link") { store.copyLink(bookmark.url) }
            Divider()
            Button("Remove Bookmark") { store.removeBookmark(bookmark) }
        }
        .help("\(bookmark.title)\n\(bookmark.url)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(openTab?.active == true || store.selectedSidebarItems.contains(.bookmark(bookmark.id)) ? [.isButton, .isSelected] : .isButton)
    }
}
