import SafariServices
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var drag = SidebarDrag()

    var body: some View {
        VStack(spacing: 0) {
            if let selection = store.currentWindow {
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
                        if settings.showBookmarks {
                            BookmarksSection()
                            Divider()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                        }
                        TabsSection(selection: selection)
                    }
                    .coordinateSpace(.named(SidebarDrag.coordinateSpace))
                    .overlay(alignment: .topLeading) {
                        if let item = drag.item {
                            DragGhost(item: item)
                                .offset(y: drag.ghostTop)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.automatic)
            } else {
                EmptySidebar()
            }
        }
        .environment(drag)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct BookmarksSection: View {
    @Environment(TabStore.self) private var store
    @Environment(SidebarDrag.self) private var drag

    private enum Slot: Identifiable {
        case bookmark(Bookmark)
        case dropSlot

        var id: String {
            switch self {
            case .bookmark(let bookmark): bookmark.id.uuidString
            case .dropSlot: "drop-slot"
            }
        }
    }

    /// Bookmarks in display order. While a bookmark is dragged over the list it moves to the
    /// target slot (and draws itself as the slot); a dragged tab gets a separate slot.
    private var slots: [Slot] {
        var bookmarks = store.bookmarks
        switch (drag.item, drag.target) {
        case (.bookmark(let dragged)?, .bookmarks(let index)):
            if let from = bookmarks.firstIndex(where: { $0.id == dragged.id }) {
                let moved = bookmarks.remove(at: from)
                bookmarks.insert(moved, at: min(index, bookmarks.count))
            }
            return bookmarks.map(Slot.bookmark)
        case (.tab?, .bookmarks(let index)):
            var slots = bookmarks.map(Slot.bookmark)
            slots.insert(.dropSlot, at: min(index, slots.count))
            return slots
        default:
            return bookmarks.map(Slot.bookmark)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Bookmarks") {
                SidebarIconButton(systemImage: "plus", help: "Bookmark Current Tab") {
                    store.addBookmarkForCurrentTab()
                }
            }

            VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
                ForEach(slots) { slot in
                    switch slot {
                    case .bookmark(let bookmark):
                        BookmarkRow(bookmark: bookmark)
                    case .dropSlot:
                        DropSlot()
                    }
                }
            }
            .onSidebarTop { drag.bookmarkRowsTop = $0 }

            if store.bookmarks.isEmpty && drag.target == .none {
                Text("Drag a tab here, or click + to bookmark the current page.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onSidebarTop { drag.bookmarksSectionTop = $0 }
        // Links dragged in from a web page or Safari's address bar.
        .onDrop(of: [.url], isTargeted: nil) { providers, location in
            let index = drag.bookmarkIndex(forDropAt: location.y, count: store.bookmarks.count)
            return loadDroppedURL(from: providers) { url in
                store.addBookmark(url: url, at: index)
            }
        }
    }
}

private struct TabsSection: View {
    let selection: TabStore.WindowSelection
    @Environment(TabStore.self) private var store
    @Environment(SidebarDrag.self) private var drag

    /// Tabs in display order; a tab dragged within the list moves to the target slot.
    private var tabs: [BrowserTab] {
        var tabs = selection.window.tabs
        if case .tab(let dragged, _)? = drag.item, case .tabs(let index) = drag.target,
           let from = tabs.firstIndex(where: { $0.id == dragged.id }) {
            let moved = tabs.remove(at: from)
            tabs.insert(moved, at: min(index, tabs.count))
        }
        return tabs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Tabs", detail: "\(selection.window.tabs.count)") {
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
