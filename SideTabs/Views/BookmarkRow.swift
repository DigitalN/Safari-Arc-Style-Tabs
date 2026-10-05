import SwiftUI
import UniformTypeIdentifiers

struct BookmarkRow: View {
    let bookmark: Bookmark

    @Environment(TabStore.self) private var store
    @State private var hovering = false

    private var isRenaming: Bool { store.renaming == .bookmark(bookmark.id) }

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
        .frame(height: 30)
        .background(RowBackground(isActive: openTab?.active == true, isHovering: hovering))
        .background(MouseTracking(onHover: { hovering = $0 }))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            store.open(bookmark, inNewTab: NSEvent.modifierFlags.contains(.command))
        }
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
        .onDrag {
            store.beginDrag(.bookmark(bookmark.id))
            if let url = URL(string: bookmark.url) {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider(object: bookmark.title as NSString)
        }
        .onDrop(of: [.url, .plainText], delegate: BookmarkDropDelegate(target: bookmark, store: store))
        .help("\(bookmark.title)\n\(bookmark.url)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Reorders bookmarks, and turns dropped tabs or links into bookmarks.
struct BookmarkDropDelegate: DropDelegate {
    /// nil means "append to the end".
    let target: Bookmark?
    let store: TabStore

    func dropEntered(info: DropInfo) {
        guard let target, case .bookmark(let id)? = store.dragging else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            store.previewMove(bookmark: id, over: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if case .bookmark? = store.dragging {
            return DropProposal(operation: .move)
        }
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = target.flatMap { target in store.bookmarks.firstIndex { $0.id == target.id } }
        switch store.dragging {
        case .bookmark?:
            store.finishDrag()
            return true
        case .tab(let key)?:
            store.cancelDrag()
            guard let tab = store.tab(for: key) else { return false }
            store.addBookmark(from: tab, instance: key.instance, at: index)
            return true
        case nil:
            return loadDroppedURL(info) { url in store.addBookmark(url: url, at: index) }
        }
    }
}
