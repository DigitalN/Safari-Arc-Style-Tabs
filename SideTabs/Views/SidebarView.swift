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
                if !store.validSidebarSelection.isEmpty {
                    HStack {
                        Text("\(store.validSidebarSelection.count) selected").font(.caption)
                        Spacer()
                        Menu("Actions") { BulkSelectionActions() }
                        SidebarIconButton(systemImage: "xmark", help: "Clear Selection") { store.clearSidebarSelection() }
                    }.padding(.horizontal, 12).padding(.vertical, 4)
                }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if store.lacksWebsiteAccess {
                            WebsiteAccessBanner()
                                .padding(.bottom, 8)
                        }
                        if settings.showBookmarks && !store.favorites.isEmpty {
                            FavoritesSection()
                                .padding(.bottom, 8)
                        }
                        SpaceHeader()
                        if settings.showBookmarks {
                            PinnedSection()
                            Divider()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                        }
                        TabsSection(selection: selection)
                        if store.arcPendingTabs.contains(where: { $0.spaceID == store.selectedSpace.id }) {
                            Button("Restore queued Arc tabs…") { store.onOpenArcImport?() }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                    }
                    .coordinateSpace(.named(SidebarDrag.coordinateSpace))
                    .overlay(alignment: .topLeading) {
                        if let item = drag.item {
                            DragGhost(item: drag.items.first ?? item, count: drag.items.count)
                                .offset(y: drag.ghostTop)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.automatic)
                SpaceSwitcher()
            } else {
                EmptySidebar()
            }
        }
        .background(spaceColor(store.selectedSpace.theme).opacity(0.08))
        .onChange(of: store.selectedSpace.id) { _, _ in drag.cancel() }
        .onChange(of: store.sidebarSelectionContext) { _, _ in drag.cancel(); store.clearSidebarSelection() }
        .onAppear { store.selectionShowsBookmarks = settings.showBookmarks }
        .onChange(of: settings.showBookmarks) { _, show in
            drag.cancel(); store.clearSidebarSelection(); store.selectionShowsBookmarks = show
        }
        // A sheet on the stable sidebar root survives row updates and holds focus
        // while the pointer leaves an auto-hiding sidebar to choose an action.
        .alert(store.pendingSidebarDeletion?.title ?? "Delete?", isPresented: Binding(
            get: { store.isConfirmingSidebarDeletion }, set: { store.isConfirmingSidebarDeletion = $0 }),
               presenting: store.pendingSidebarDeletion) { deletion in
            switch deletion {
            case .folder(let folder):
                Button("Remove Folder, Keep Contents") { store.removeFolder(folder.id) }
                Button("Delete Folder and All Its Tabs", role: .destructive) { store.removeFolder(folder.id, deleteContents: true) }
            case .space(let space):
                Button("Move Items to \(store.spaces.first { $0.id != space.id }?.name ?? "Another Space") and Delete Space") {
                    store.deleteSpace(space.id)
                }
                Button("Delete Space and All Its Tabs", role: .destructive) { store.deleteSpace(space.id, deleteContents: true) }
            case .selection(let items, let context):
                Button("Delete Selected Tabs", role: .destructive) { store.deleteSidebarSelection(items, context: context) }
            }
            Button("Cancel", role: .cancel) { store.pendingSidebarDeletion = nil }
        } message: { deletion in
            switch deletion {
            case .folder:
                Text("Keep the contents in the parent folder, or delete all saved tabs and nested folders and close their open Safari tabs. Other copies of the same page are kept.")
            case .space:
                Text("Move the contents to another space, or delete its saved tabs and folders and close its open Safari tabs in all windows. Shared Favorites are kept.")
            case .selection:
                Text("Selected saved tabs will be removed and their open tabs closed. Other copies of the same page and folders are kept.")
            }
        }
        .environment(drag)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct BulkSelectionActions: View {
    @Environment(TabStore.self) private var store
    var body: some View {
        Button("Delete \(store.validSidebarSelection.count) Selected Tabs…", role: .destructive) { store.requestDeleteSidebarSelection() }
        Menu("Move Selected Tabs to Space") {
            ForEach(store.spaces) { space in
                Button { store.moveSidebarSelection(to: space.id) } label: {
                    Label { Text(space.name) } icon: { SpaceIcon(space: space) }
                }.disabled(space.id == store.selectedSpace.id)
            }
        }
        Button("Clear Selection") { store.clearSidebarSelection() }
    }
}

private struct TabsSection: View {
    let selection: TabStore.WindowSelection
    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SidebarDrag.self) private var drag

    /// Preview the selected group together at its destination slot.
    private var tabs: [BrowserTab] {
        drag.previewTabs(store.displayedTabs(in: selection, showBookmarks: settings.showBookmarks))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Tabs", detail: "\(store.displayedTabs(in: selection, showBookmarks: settings.showBookmarks).count)") {
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
