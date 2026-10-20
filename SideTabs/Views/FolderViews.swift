import SwiftUI
import UniformTypeIdentifiers

struct PinnedSection: View {
    @Environment(TabStore.self) private var store
    @Environment(SidebarDrag.self) private var drag

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Pinned") {
                SidebarIconButton(systemImage: "folder.badge.plus", help: "New Folder") {
                    let folder = store.createFolder()
                    store.beginRename(.folder(folder.id))
                }
                SidebarIconButton(systemImage: "plus", help: "Pin Current Tab in This Space") {
                    store.addBookmarkForCurrentTab()
                }
            }
            ForEach(store.visiblePinnedEntries) { entry in
                Group {
                    switch entry.item {
                    case .folder(let id):
                        if let folder = store.folder(id) { FolderRow(folder: folder) }
                    case .bookmark(let id):
                        if let bookmark = store.bookmark(id) { BookmarkRow(bookmark: bookmark) }
                    }
                }
                .padding(.leading, CGFloat(min(entry.depth, 5)) * 12)
                .overlay(alignment: .top) {
                    if drag.isInsertionBefore(entry.item, store: store) {
                        Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                    }
                }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(SidebarDrag.coordinateSpace))
                } action: { rect in drag.pinnedFrames[entry.item] = rect }
                .onDisappear { drag.pinnedFrames[entry.item] = nil }
            }
            if store.pinnedChildren().isEmpty {
                Text("Drag a tab here to pin it, or create a folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
        .onSidebarTop { drag.bookmarksSectionTop = $0 }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            loadDroppedURL(from: providers) { store.addBookmark(url: $0) }
        }
    }
}

struct FolderRow: View {
    let folder: PinnedFolder
    @Environment(TabStore.self) private var store
    @Environment(SidebarDrag.self) private var drag
    @Environment(AppSettings.self) private var settings
    @State private var hovering = false
    @State private var rowTop: CGFloat = 0
    private var renaming: Bool { store.renaming == .folder(folder.id) }
    private var targeted: Bool { drag.target == .pinned(folderID: folder.id, index: nil) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 10)
            Image(systemName: folder.isExpanded ? "folder.fill" : "folder")
                .foregroundStyle(spaceColor(store.selectedSpace.theme))
                .frame(width: 16)
            if renaming {
                RenameField(text: folder.name, onCommit: store.commitRename, onCancel: store.cancelRename)
            } else {
                Text(folder.name).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if !renaming {
                Text("\(store.pinnedChildren(of: folder.id).count)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: SidebarDrag.rowHeight)
        .background(RowBackground(isActive: targeted, isHovering: hovering && !drag.isActive))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor.opacity(targeted ? 0.8 : 0), lineWidth: 1.5))
        .opacity(drag.isSlot(folder: folder) ? 0.3 : 1)
        .background(MouseTracking(onHover: { hovering = $0 }))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !renaming else { return }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { store.beginRename(.folder(folder.id)) }
            else { withAnimation(.snappy(duration: 0.18)) { store.toggleFolder(folder.id) } }
        }
        .sidebarDraggable(.folder(folder), drag: drag, store: store, settings: settings, rowTop: rowTop, enabled: !renaming)
        .onSidebarTop { rowTop = $0 }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            loadDroppedURL(from: providers) { store.addBookmark(url: $0, folderID: folder.id) }
        }
        .contextMenu {
            Button("New Subfolder") {
                let child = store.createFolder(parentID: folder.id)
                store.beginRename(.folder(child.id))
            }
            Button("Rename Folder…") { store.beginRename(.folder(folder.id)) }
            Menu("Move Folder To") { FolderDestinations(item: .folder(folder.id)) }
            Menu("Move to Space") {
                ForEach(store.spaces) { space in
                    Button(space.name) { store.movePinnedItem(.folder(folder.id), to: nil, spaceID: space.id) }
                        .disabled(space.id == folder.spaceID)
                }
            }
            Button("Move Up") { store.reorderPinnedItem(.folder(folder.id), direction: -1) }
            Button("Move Down") { store.reorderPinnedItem(.folder(folder.id), direction: 1) }
            Divider()
            Button("Delete Folder…") { store.requestDeleteFolder(folder.id) }
        }
        .help(store.folderPath(folder.id))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: folder.isExpanded ? "Collapse" : "Expand") { store.toggleFolder(folder.id) }
        .accessibilityLabel("\(folder.name), \(folder.isExpanded ? "expanded" : "collapsed") folder")
    }
}

/// Full paths distinguish identically named folders and include collapsed descendants.
struct FolderDestinations: View {
    let item: PinnedItem?
    var onPin: ((UUID?) -> Void)? = nil
    @Environment(TabStore.self) private var store
    private func move(_ destination: UUID?) {
        if let onPin { onPin(destination) }
        else if let item { store.movePinnedItem(item, to: destination) }
    }
    var body: some View {
        Button("Pinned (Top Level)") { move(nil) }
        ForEach(store.pinnedEntries(includeCollapsed: true).filter { if case .folder = $0.item { true } else { false } }) { entry in
            if case .folder(let id) = entry.item {
                Button { move(id) } label: { Label(store.folderPath(id), systemImage: "folder") }
                    .disabled(item.map { !store.canMovePinnedItem($0, into: id) } ?? false)
            }
        }
    }
}
