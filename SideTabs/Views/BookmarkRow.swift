import SwiftUI

struct BookmarkRow: View {
    let bookmark: Bookmark

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
        .onTapGesture {
            guard !isRenaming else { return }
            store.open(bookmark, inNewTab: NSEvent.modifierFlags.contains(.command))
        }
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
