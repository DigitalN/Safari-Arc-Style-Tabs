import SafariServices
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarRows.self) private var rows
    @State private var drag = SidebarDrag()
    @State private var showsClosedTabs = false
    @Environment(SafariProfiles.self) private var profiles

    var body: some View {
        VStack(spacing: 0) {
            if profiles.profileToTurnOn != nil {
                // Side Tabs is off in the front window's profile (#33): one row to turn it on, in place
                // of the sections, which would list another window's tabs.
                TurnOnSideTabsRow()
                    .replaced(by: ClosedTabsList(isShown: $showsClosedTabs), when: showsClosedTabs && settings.closesUnviewedTabs)
                BottomBar(showsClosedTabs: $showsClosedTabs)
            } else if store.shownContent != nil || store.displayedContent != nil {
                // Centered on the same line as Safari's toolbar when docked.
                AddressBar()
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if store.lacksWebsiteAccess {
                            WebsiteAccessBanner()
                                .padding(.bottom, 8)
                        }
                        // While a switch's window comes back from the Dock, the sections fade over to its
                        // profile (#44, SidebarFade): one set of sections, never two, faded out over what was
                        // shown, swapped while nothing shows, and faded back in. The animation is scoped to the
                        // opacity alone, so a change of contents is never animated: no row is ever kept on
                        // screen for a removal transition, and Safari's report, right or not, swaps in place.
                        if let content = store.displayedContent {
                            SidebarSections(content: content)
                                .animation(store.sidebarFade.animation) { sections in
                                    sections.opacity(store.sidebarFade.opacity)
                                }
                        }
                    }
                    .coordinateSpace(.named(SidebarDrag.coordinateSpace))
                    .overlay(alignment: .topLeading) {
                        if let item = drag.item {
                            DragGhost(item: item, tileSize: drag.ghostIsTile ? max(drag.favoritesMetrics.tile, 40) : nil)
                                .offset(x: drag.ghostOrigin.x, y: drag.ghostOrigin.y)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.automatic)
                .onWindowFrame { rows.viewport = $0 }
                // The tabs cleanup closed, listed in place of the sections while that's open.
                .replaced(by: ClosedTabsList(isShown: $showsClosedTabs), when: showsClosedTabs && settings.closesUnviewedTabs)
                BottomBar(showsClosedTabs: $showsClosedTabs)
            } else {
                EmptySidebar()
            }
        }
        .environment(drag)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            // A switch's profile whose window isn't known yet (#44): its lists, and no other window's tabs.
            ProfileLists(profile: profile)
            TabsPlaceholder()
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

/// The Pinned list of the profile whose window the sidebar shows (#34). It starts out empty, and then
/// says how to pin something, so there's a place to drop tabs.
private struct PinnedSection: View {
    let list: BookmarkList
    @Environment(TabStore.self) private var store
    @Environment(SidebarDrag.self) private var drag

    private enum Slot: Identifiable {
        case pinned(Bookmark)
        case dropSlot

        var id: String {
            switch self {
            case .pinned(let item): item.id.uuidString
            case .dropSlot: "drop-slot"
            }
        }
    }

    /// Pinned items in display order. While one is dragged over the list it moves to the target
    /// slot (and draws itself as the slot); a dragged tab or favorite gets a separate slot.
    private var slots: [Slot] {
        var items = store.bookmarks(in: list)
        switch (drag.item, drag.target) {
        case (.pinned(let dragged)?, .pinned(let index)):
            if let from = items.firstIndex(where: { $0.id == dragged.id }) {
                let moved = items.remove(at: from)
                items.insert(moved, at: min(index, items.count))
            }
            return items.map(Slot.pinned)
        case (.tab?, .pinned(let index)), (.favorite?, .pinned(let index)):
            var slots = items.map(Slot.pinned)
            slots.insert(.dropSlot, at: min(index, slots.count))
            return slots
        default:
            return items.map(Slot.pinned)
        }
    }

    var body: some View {
        let isEmpty = store.bookmarks(in: list).isEmpty
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Pinned") {
                SidebarIconButton(systemImage: "plus", help: "Pin Current Tab") {
                    store.addBookmarkForCurrentTab()
                }
            }

            VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
                ForEach(slots) { slot in
                    switch slot {
                    case .pinned(let item):
                        BookmarkRow(bookmark: item)
                    case .dropSlot:
                        DropSlot()
                    }
                }
            }
            .onSidebarTop { drag.pinnedRowsTop = $0 }

            if isEmpty && drag.target == .none {
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
        // Links dragged in from a web page or Safari's address bar.
        .onDrop(of: [.url], isTargeted: nil) { providers, location in
            let index = drag.pinnedIndex(forDropAt: location.y, count: store.bookmarks(in: list).count)
            return loadDroppedURL(from: providers) { url in
                store.addBookmark(url: url, to: list, at: index)
            }
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

    /// Tabs in display order; a tab dragged within the list moves to the target slot.
    private var tabs: [BrowserTab] {
        var tabs = listed
        if case .tab(let dragged, _)? = drag.item, case .tabs(let index) = drag.target,
           let from = tabs.firstIndex(where: { $0.id == dragged.id }) {
            let moved = tabs.remove(at: from)
            tabs.insert(moved, at: min(index, tabs.count))
        }
        return tabs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Tabs", detail: "\(listed.count)") {
                SidebarIconButton(systemImage: "plus", help: "New Tab") {
                    store.newTab()
                }
            }

            VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
                ForEach(tabs) { tab in
                    TabRow(tab: tab, instance: selection.instance)
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
