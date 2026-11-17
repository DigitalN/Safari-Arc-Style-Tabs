import SwiftUI

/// A folder in the Pinned list (#76). A click anywhere on the row opens or closes it, when the button goes up, so a
/// press that turns into a drag doesn't. Like every left click on the sidebar, it brings Safari forward
/// (SidebarPanel). While it's collapsed, a count on the right says how many tabs of the items inside are open in this
/// window: those tabs aren't listed under Tabs (#25), so without it they'd be shown nowhere.
struct FolderRow: View {
    let folder: PinnedFolder
    let depth: Int
    /// Whether its contents show: it's open, or sprang open during a drag.
    let expanded: Bool
    /// The tabs of the items inside it, at any depth, that are open in this window.
    let openTabs: Int
    let list: BookmarkList

    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarDrag.self) private var drag
    @State private var hovering = false
    @State private var rowTop: CGFloat = 0

    private var isRenaming: Bool { store.renaming == .folder(folder.id) }
    private var isSlot: Bool { drag.isSlot(pinned: folder.id) }
    private var isTucked: Bool { drag.isTucked(folder.id) }
    private var isDropTarget: Bool { drag.pinnedDrop == .into(folder.id) }
    private var showsCount: Bool { !expanded && openTabs > 0 && !isRenaming }

    private func toggle() {
        guard !isRenaming else { return }
        store.toggleFolder(folder.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            FolderIcon(isOpen: expanded)

            if isRenaming {
                RenameField(text: folder.name, onCommit: store.commitRename, onCancel: store.cancelRename)
            } else {
                Text(folder.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if showsCount {
                // Where a pinned row's "−" sits. It does nothing on hover.
                Text("\(openTabs)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20)
            }
        }
        .font(.system(size: 13))
        .padding(.leading, PinnedOutline.leading + CGFloat(depth) * PinnedOutline.indent)
        .padding(.trailing, showsCount ? 4 : 8)
        .frame(height: SidebarDrag.rowHeight)
        .background(RowBackground(isActive: false, isHovering: hovering && !drag.isActive))
        .background(FolderDropHighlight(isOn: isDropTarget))
        .background(MouseTracking(onHover: { hovering = $0 }))
        .opacity(isSlot || isTucked ? 0 : 1)
        .overlay {
            if isSlot {
                DropSlot()
                    .padding(.leading, CGFloat(depth) * PinnedOutline.indent)
            }
        }
        .contentShape(Rectangle())
        .sidebarRowGesture(
            .folder(folder),
            drag: drag,
            store: store,
            settings: settings,
            rowTop: rowTop,
            dragEnabled: !isRenaming,
            onPress: { _ in !isRenaming },
            onClick: toggle
        )
        .onSidebarTop { rowTop = $0 }
        .contextMenu { FolderMenu(folder: folder, list: list, hasOpenTabs: openTabs > 0) }
        .help(folder.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(folder.name)
        .accessibilityValue(openTabs > 0 ? "\(expanded ? "expanded" : "collapsed"), \(openTabs) open" : expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityAction(named: expanded ? "Collapse" : "Expand") { toggle() }
        .tucked(isTucked)
    }
}

/// A folder's menu (#76).
struct FolderMenu: View {
    let folder: PinnedFolder
    let list: BookmarkList
    /// Whether any item inside it, at any depth, has a tab open in the window the sidebar shows.
    let hasOpenTabs: Bool
    @Environment(TabStore.self) private var store

    var body: some View {
        Button("Rename…") { store.beginRename(.folder(folder.id)) }
        Button("New Folder") { store.newFolder(in: list, .inside(folder.id)) }
        Divider()
        if hasOpenTabs {
            Button("Close Tabs") { store.closeTabs(inFolder: folder.id) }
        }
        Button("Delete Folder") { store.deleteFolder(folder.id) }
    }
}

/// "Empty", under an open folder with nothing in it. Dropping on it puts the item in the folder.
struct EmptyFolderRow: View {
    let folder: UUID
    let depth: Int
    @Environment(SidebarDrag.self) private var drag

    var body: some View {
        Text("Empty")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.leading, PinnedOutline.leading + CGFloat(depth) * PinnedOutline.indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SidebarDrag.rowHeight)
            .background(FolderDropHighlight(isOn: drag.pinnedDrop == .into(folder)))
            .accessibilityLabel("Empty folder")
    }
}

/// The highlight of a folder something would be dropped into.
private struct FolderDropHighlight: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.accentColor.opacity(isOn ? 0.14 : 0))
            .strokeBorder(Color.accentColor.opacity(isOn ? 0.7 : 0), lineWidth: 1.5)
    }
}

/// A folder's symbol, open or closed to match. SF Symbols has only a closed folder, so the open one is drawn here in
/// the same style: its back with the tab, and the front flap tipped forward.
struct FolderIcon: View {
    let isOpen: Bool

    var body: some View {
        Group {
            if isOpen {
                OpenFolderShape()
                    .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                    .frame(width: 15, height: 12)
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 13))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct OpenFolderShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        var path = Path()
        // The back, with its tab, from the bottom left up and over to where the flap meets it.
        path.move(to: point(0.04, 0.96))
        path.addLine(to: point(0.04, 0.14))
        path.addQuadCurve(to: point(0.12, 0.04), control: point(0.04, 0.04))
        path.addLine(to: point(0.36, 0.04))
        path.addLine(to: point(0.46, 0.18))
        path.addLine(to: point(0.80, 0.18))
        path.addQuadCurve(to: point(0.88, 0.28), control: point(0.88, 0.18))
        path.addLine(to: point(0.88, 0.42))
        // The flap, tipped forward over the bottom.
        path.move(to: point(0.04, 0.96))
        path.addLine(to: point(0.22, 0.42))
        path.addLine(to: point(0.98, 0.42))
        path.addLine(to: point(0.80, 0.96))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// Keeps a row in the list but takes up no room: the pinned item or folder being dragged, while it's over a
    /// folder it would go into (`SidebarDrag.isTucked`). Its view has to stay, or its drag gesture would end.
    func tucked(_ isTucked: Bool) -> some View {
        frame(height: isTucked ? 0 : nil, alignment: .top)
            .clipped()
            .accessibilityHidden(isTucked)
    }
}
