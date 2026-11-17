import SafariServices
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarSwipe.self) private var swipe
    @State private var showsClosedTabs = false

    var body: some View {
        let closedTabsShown = showsClosedTabs && settings.closesUnviewedTabs
        VStack(spacing: 0) {
            if store.shownContent != nil || store.displayedContent != nil {
                // Everything above the bottom bar is one page, which a swipe slides aside for the next profile's
                // (#72). The tabs cleanup closed are listed in place of it while that's open.
                SidebarPages()
                    .replaced(by: ClosedTabsList(isShown: $showsClosedTabs), when: closedTabsShown)
                BottomBar(showsClosedTabs: $showsClosedTabs)
            } else {
                if let copy = store.otherExtensionCopy {
                    OtherCopyBanner(copy: copy)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                }
                EmptySidebar()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: closedTabsShown, initial: true) { swipe.isBlocked = closedTabsShown }
    }
}

extension EnvironmentValues {
    /// The window the page around a view shows (#72): its rows' state is that window's, which during a swipe isn't
    /// the one commands act on. Nil for a page that shows no window.
    @Entry var sidebarPageWindow: TabStore.SidebarPageWindow? = nil
}

/// The page in place, and during a swipe the pages beside it (SidebarSwipe), each in a slot of its own, so a page
/// keeps its scroll position as it goes from sliding in to in place, or from in place to sliding out.
private struct SidebarPages: View {
    @Environment(SidebarSwipe.self) private var swipe

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(0..<3, id: \.self) { slot in
                SidebarSlot(slot: slot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { swipe.pageWidth = $0 }
    }
}

/// One of the three slots: the page in place (the sidebar's own contents), a page sliding in or out beside it, or
/// nothing. Each has its own reorder state, so a page beside the one in place can't disturb a drag on it.
private struct SidebarSlot: View {
    let slot: Int
    @Environment(TabStore.self) private var store
    @Environment(SidebarSwipe.self) private var swipe
    @State private var drag = SidebarDrag()

    var body: some View {
        if let place = swipe.slots.place(of: slot) {
            let inPlace = place == 0
            SidebarPage(content: inPlace ? store.displayedContent : swipe.slots.content(of: slot), inPlace: inPlace)
                .environment(drag)
                .modifier(SlotOffset(place: place))
                // Only the page in place takes clicks.
                .allowsHitTesting(inPlace)
                .accessibilityHidden(!inPlace)
        }
    }
}

/// Where a slot's page is: with the swipe, and a page's width either side for one beside the page in place. Read
/// here, so the page itself isn't drawn again as it moves.
private struct SlotOffset: ViewModifier {
    let place: Int
    @Environment(SidebarSwipe.self) private var swipe

    func body(content: Content) -> some View {
        content.offset(x: swipe.offset + CGFloat(place) * swipe.pageWidth)
    }
}

/// A page: the address bar, Favorites, Pinned and Tabs, or the row to turn Side Tabs on where it's off.
private struct SidebarPage: View {
    let content: TabStore.ShownContent?
    /// The page in place, as opposed to one sliding in or out during a swipe.
    let inPlace: Bool
    @Environment(TabStore.self) private var store
    @Environment(SidebarRows.self) private var rows
    @Environment(SidebarDrag.self) private var drag

    var body: some View {
        Group {
            if case .turnOn(let profileID)? = content {
                VStack(spacing: 0) {
                    if let copy = store.otherExtensionCopy {
                        OtherCopyBanner(copy: copy)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                    }
                    // Side Tabs is off in this profile (#33): one row to turn it on, in place of the sections,
                    // which would list another window's tabs.
                    TurnOnSideTabsRow(profileID: profileID)
                        .fading(inPlace)
                }
            } else {
                VStack(spacing: 0) {
                    // Centered on the same line as Safari's toolbar when docked.
                    AddressBar(content: content)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            if let copy = store.otherExtensionCopy {
                                OtherCopyBanner(copy: copy)
                                    .padding(.bottom, 8)
                            }
                            if store.lacksWebsiteAccess {
                                WebsiteAccessBanner()
                                    .padding(.bottom, 8)
                            }
                            if let content {
                                SidebarSections(content: content)
                                    .fading(inPlace)
                            }
                        }
                        .coordinateSpace(.named(SidebarDrag.coordinateSpace))
                        .overlay(alignment: .topLeading) {
                            if let item = drag.item {
                                DragGhost(item: item, tileSize: drag.ghostIsTile ? max(drag.favoritesMetrics.tile, 40) : nil)
                                    // Over a folder it would go into, it fades so the folder's highlight shows (#76).
                                    .opacity(drag.isOverFolder ? 0.5 : 1)
                                    .offset(x: drag.ghostOrigin.x, y: drag.ghostOrigin.y)
                                    .allowsHitTesting(false)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                    }
                    .scrollIndicators(.automatic)
                    // A middle click looks rows up in the list in place only.
                    .onWindowFrame { frame in
                        if inPlace { rows.viewport = frame }
                    }
                }
            }
        }
        .environment(\.sidebarPageWindow, TabStore.SidebarPageWindow(content))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private extension View {
    /// While a switch's window comes back from the Dock, the page in place fades over to its profile (#44,
    /// SidebarFade): one set of sections, never two, faded out over what was shown, swapped while nothing shows, and
    /// faded back in. The animation is scoped to the opacity alone, so a change of contents is never animated: no
    /// row is ever kept on screen for a removal transition, and Safari's report, right or not, swaps in place. A page
    /// sliding in or out during a swipe doesn't fade.
    func fading(_ inPlace: Bool) -> some View {
        modifier(SidebarFadeOpacity(inPlace: inPlace))
    }
}

private struct SidebarFadeOpacity: ViewModifier {
    let inPlace: Bool
    @Environment(TabStore.self) private var store

    func body(content: Content) -> some View {
        content.animation(inPlace ? store.sidebarFade.animation : nil) { view in
            view.opacity(inPlace ? store.sidebarFade.opacity : 1)
        }
    }
}

extension SidebarFade {
    /// How the step to this one animates: the fade-out quickly, the fade-in until the window lands, and the
    /// swap in between, or a fade the watchdog ended, not at all.
    var animation: Animation? {
        switch phase {
        case .out(let duration): .easeIn(duration: duration)
        case .in(let duration): .easeOut(duration: duration)
        case .hidden, .none: nil
        }
    }
}

/// Favorites, Pinned and Tabs, top to bottom (#34). Favorites and Pinned are the lists of the profile whose
/// window the sidebar shows (#38), so both swap at once when another profile's window comes in front. A
/// private window belongs to no profile and shows Tabs only, and so does every window with Favorites and
/// Pinned turned off in Settings.
private struct SidebarSections: View {
    /// What to show (TabStore.displayedContent).
    let content: TabStore.ShownContent
    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        switch content {
        case .window(let selection):
            // A private window belongs to no profile, so it shows Tabs only (#38).
            if let profile = store.profile(of: selection.window, instance: selection.instance) {
                ProfileLists(profile: profile)
            }
            TabsSection(selection: selection)
        case .unseen(let profile):
            // Its own profile's lists as usual, and its tabs as the tab bar shows them: never another
            // profile's window's (#41).
            if let profile {
                ProfileLists(profile: profile)
            }
            UnseenWindowTabsSection(isPrivate: profile == nil)
        case .placeholder(let profile):
            // A switch's profile whose window isn't known yet (#44): its lists, and no other window's tabs. None for
            // a profile whose copy isn't known yet (#72).
            if let profile {
                ProfileLists(profile: profile)
            }
            TabsPlaceholder()
        case .turnOn:
            // Drawn by SidebarPage in place of the sections.
            EmptyView()
        }
    }
}

/// A profile's Favorites and Pinned, unless they're turned off in Settings.
private struct ProfileLists: View {
    let profile: ProfileKey
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if settings.showBookmarks {
            FavoritesSection(list: .favorites(profile))
            PinnedSection(list: .pinned(profile))
            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
        }
    }
}

/// In place of Tabs while a switch's window is on its way and which window it is can't be told (#44): quiet,
/// and never another window's tabs. Safari's report replaces it in a few tenths of a second.
private struct TabsPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Tabs") {
                EmptyView()
            }
            ForEach(0..<3, id: \.self) { row in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .frame(height: 12)
                    .frame(maxWidth: row == 2 ? 120 : .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tabs, loading")
    }
}

/// The Pinned list of the profile whose window the sidebar shows (#34), with its folders (#76). It starts out empty,
/// and then says how to pin something, so there's a place to drop tabs.
private struct PinnedSection: View {
    let list: BookmarkList
    @Environment(TabStore.self) private var store
    @Environment(SidebarDrag.self) private var drag
    @Environment(\.sidebarPageWindow) private var pageWindow

    private enum Slot: Identifiable {
        case row(PinnedOutline.Row)
        /// The open slot for a tab, a favorite's tile or a link, at its level.
        case dropSlot(depth: Int)
        /// The room the slot was in, kept open but empty while a folder is the target, so the rows don't move.
        case room

        var id: String {
            switch self {
            case .row(let row): row.id
            // One id for both, so the slot fades into the empty room and back.
            case .dropSlot, .room: "drop-slot"
            }
        }
    }

    private var tree: [PinnedNode] { store.pinnedTree(in: list) }

    /// The pinned item whose tab is the active one in the window this page shows.
    private var active: UUID? {
        store.bookmarks(in: list).first { store.openTab(for: $0, inPage: pageWindow)?.active == true }?.id
    }

    /// The rows in display order (see PinnedOutline), laid out as the drag works them out: without what's dragged,
    /// with its room open at `SidebarDrag.pinnedSpacer`. A pinned item or folder dragged over a slot moves there and
    /// draws itself as the slot; over a folder it would go into, it stays in that room without being drawn. A
    /// dragged tab, tile or link gets a separate slot, or an empty room.
    private var slots: [Slot] {
        let tree = tree
        let active = active
        let isOpen = { (bookmark: Bookmark) in store.openTab(for: bookmark, inPage: pageWindow) != nil }
        let shown = drag.pinnedOutline(tree: tree, active: active, isOpen: isOpen, hidingDragged: false)
        let drop = drag.pinnedDrop
        let room = drag.pinnedSpacer
        guard let dragged = drag.draggedNode, let drop else {
            var slots = shown.rows.map(Slot.row)
            switch drop {
            case .slot(let gap, let depth, _)?:
                slots.insert(.dropSlot(depth: depth), at: min(gap, slots.count))
            case .into?:
                if let room {
                    slots.insert(.room, at: min(room, slots.count))
                }
            case nil:
                break
            }
            return slots
        }
        let others = drag.pinnedOutline(tree: tree, active: active, isOpen: isOpen, hidingDragged: true)
        var slots = others.rows.map(Slot.row)
        guard let row = shown.rows.first(where: { $0.kind.node == dragged }) else { return slots }
        switch drop {
        case .slot(let gap, let depth, _):
            slots.insert(.row(PinnedOutline.Row(kind: row.kind, depth: depth, steps: row.steps)), at: min(gap, slots.count))
        case .into:
            slots.insert(.row(row), at: min(room ?? slots.count, slots.count))
        }
        return slots
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Pinned") {
                SidebarIconButton(systemImage: "plus", help: "Pin Current Tab") {
                    store.addBookmarkForCurrentTab()
                }
            }

            VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
                ForEach(slots) { slot in
                    switch slot {
                    case .row(let row):
                        PinnedRowView(row: row, list: list)
                    case .dropSlot(let depth):
                        DropSlot()
                            .padding(.leading, CGFloat(depth) * PinnedOutline.indent)
                    case .room:
                        Color.clear
                            .frame(height: SidebarDrag.rowHeight)
                    }
                }
            }
            .onSidebarTop { drag.pinnedRowsTop = $0 }

            if tree.isEmpty && drag.target == .none && drag.linkTarget == nil {
                Text("Drag a tab here, or click + to pin the current page.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onSidebarTop { drag.pinnedSectionTop = $0 }
        // On the header or blank space: a folder at the end of the top level. Rows have menus of their own (#76).
        .contextMenu {
            Button("New Folder") { store.newFolder(in: list, .end) }
        }
        // Links dragged in from a web page or Safari's address bar.
        .onDrop(of: [.url], delegate: PinnedLinkDrop(list: list, tree: tree, active: active, store: store, drag: drag))
    }
}

/// One row of Pinned: a pinned item, a folder, or "Empty" under an open folder (#76).
private struct PinnedRowView: View {
    let row: PinnedOutline.Row
    let list: BookmarkList

    var body: some View {
        switch row.kind {
        case .bookmark(let bookmark), .activeUnder(let bookmark, _):
            BookmarkRow(bookmark: bookmark, depth: row.depth)
        case .folder(let folder, let expanded, let openTabs):
            FolderRow(folder: folder, depth: row.depth, expanded: expanded, openTabs: openTabs, list: list)
        case .empty(let folder):
            EmptyFolderRow(folder: folder, depth: row.depth, list: list)
        }
    }
}

/// A link dragged over Pinned from a web page or Safari's address bar: it lands where a dragged row would, the
/// slot or folder showing while it's over the list, and closed folders spring open under it (#76).
private struct PinnedLinkDrop: DropDelegate {
    let list: BookmarkList
    let tree: [PinnedNode]
    let active: UUID?
    let store: TabStore
    let drag: SidebarDrag

    func validateDrop(info: DropInfo) -> Bool {
        !drag.isActive && info.hasItemsConforming(to: [.url])
    }

    func dropEntered(info: DropInfo) {
        drag.updateLink(at: info.location, tree: tree, active: active)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drag.updateLink(at: info.location, tree: tree, active: active)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        drag.endLink()
    }

    func performDrop(info: DropInfo) -> Bool {
        let (drop, sprung) = drag.takeLinkDrop()
        let place = drop?.place ?? .end(of: nil)
        // The folders that sprang open and are still open are those it's dropped in: they stay open.
        for folder in sprung {
            store.setFolderOpen(folder, true)
        }
        return loadDroppedURL(from: info.itemProviders(for: [.url])) { [store, list] url in
            store.addBookmark(url: url, to: list, in: place)
        }
    }
}

private struct TabsSection: View {
    let selection: TabStore.WindowSelection
    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarDrag.self) private var drag

    /// The window's tabs except the tabs of its favorites and pinned items, which their tiles and
    /// rows stand for.
    private var listed: [BrowserTab] {
        store.tabsListed(in: selection.window, instance: selection.instance, bookmarksShown: settings.showBookmarks)
    }

    private enum Slot: Identifiable {
        case tab(BrowserTab)
        case dropSlot

        var id: String {
            switch self {
            case .tab(let tab): "tab-\(tab.id)"
            case .dropSlot: "drop-slot"
            }
        }
    }

    /// Tabs in display order. A tab dragged within the list moves to the target slot (and draws itself as the
    /// slot); a favorite or pinned item dragged here to be unpinned gets a slot of its own (#75).
    private var slots: [Slot] {
        var tabs = listed
        switch (drag.item, drag.target) {
        case (.tab(let dragged, _)?, .tabs(let index)):
            if let from = tabs.firstIndex(where: { $0.id == dragged.id }) {
                let moved = tabs.remove(at: from)
                tabs.insert(moved, at: min(index, tabs.count))
            }
            return tabs.map(Slot.tab)
        case (.favorite?, .tabs(let index)), (.pinned?, .tabs(let index)):
            var slots = tabs.map(Slot.tab)
            slots.insert(.dropSlot, at: min(index, slots.count))
            return slots
        default:
            return tabs.map(Slot.tab)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Tabs", detail: "\(listed.count)") {
                SidebarIconButton(systemImage: "plus", help: "New Tab") {
                    store.newTab()
                }
            }

            VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
                ForEach(slots) { slot in
                    switch slot {
                    case .tab(let tab):
                        TabRow(tab: tab, instance: selection.instance)
                    case .dropSlot:
                        DropSlot()
                    }
                }
            }
            .onSidebarTop { drag.tabRowsTop = $0 }

            NewTabRow()
        }
        .onSidebarTop { drag.tabsSectionTop = $0 }
        // Links dragged in from a web page open in a new tab.
        .onDrop(of: [.url], isTargeted: nil) { providers in
            loadDroppedURL(from: providers) { url in
                store.newTab(url: url.absoluteString)
            }
        }
    }
}

/// Safari runs another copy of Side Tabs' extension, and registering this app's in its place didn't make it
/// switch (#67): the sidebar's commands can't reach Safari. Says where the other copy is, so it can be deleted.
/// It goes away once this app's extension talks to it.
private struct OtherCopyBanner: View {
    let copy: ExtensionCopyCheck.OtherCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Safari is using another copy of Side Tabs")
                .font(.system(size: 12, weight: .semibold))
            Text(copy.path == nil
                 ? "Closing, opening and moving tabs from the sidebar won't work until Safari uses this copy."
                 : "Closing, opening and moving tabs from the sidebar won't work until Safari uses this copy. The other one is here:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let path = copy.path {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if FileManager.default.fileExists(atPath: path) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.yellow.opacity(0.15)))
    }
}

private struct WebsiteAccessBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Allow Side Tabs on all websites")
                .font(.system(size: 12, weight: .semibold))
            Text("Safari hides tab titles and icons until the extension is allowed on other websites.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Safari Settings") {
                SFSafariApplication.showPreferencesForExtension(withIdentifier: SideTabsBridge.extensionBundleIdentifier)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.yellow.opacity(0.15)))
    }
}

private struct EmptySidebar: View {
    @Environment(TabStore.self) private var store
    /// nil until Safari answers; checked rather than inferred from silence, because the
    /// extension is quiet for a few seconds whenever Safari or Side Tabs restarts.
    @State private var extensionEnabled: Bool?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            if extensionEnabled == false {
                Text("Side Tabs is turned off in Safari")
                    .font(.headline)
                Text("Turn it on in Safari → Settings → Extensions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Safari Extensions") {
                    Permissions.openExtensionSettings()
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                Text(store.isConnected ? "Loading tabs…" : "Connecting to Safari…")
                    .font(.headline)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                extensionEnabled = await Permissions.extensionEnabled()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
