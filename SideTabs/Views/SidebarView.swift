import SafariServices
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if let selection = store.currentWindow {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 1) {
                        if store.lacksWebsiteAccess {
                            WebsiteAccessBanner()
                                .padding(.bottom, 8)
                        }
                        if settings.showBookmarks {
                            BookmarksSection()
                            Divider()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                        TabsSection(selection: selection)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.automatic)
            } else {
                EmptySidebar()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct BookmarksSection: View {
    @Environment(TabStore.self) private var store

    var body: some View {
        SectionHeader(title: "Bookmarks") {
            SidebarIconButton(systemImage: "plus", help: "Bookmark Current Tab") {
                store.addBookmarkForCurrentTab()
            }
        }
        .onDrop(of: [.url, .plainText], delegate: BookmarkDropDelegate(target: nil, store: store))

        ForEach(store.bookmarks) { bookmark in
            BookmarkRow(bookmark: bookmark)
        }

        if store.bookmarks.isEmpty {
            Text("Drag a tab here, or click + to bookmark the current page.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onDrop(of: [.url, .plainText], delegate: BookmarkDropDelegate(target: nil, store: store))
        }
    }
}

private struct TabsSection: View {
    let selection: TabStore.WindowSelection
    @Environment(TabStore.self) private var store

    var body: some View {
        SectionHeader(title: "Tabs", detail: "\(selection.window.tabs.count)") {
            SidebarIconButton(systemImage: "plus", help: "New Tab") {
                store.newTab()
            }
        }

        ForEach(selection.window.tabs) { tab in
            TabRow(tab: tab, instance: selection.instance)
        }

        NewTabRow()
            .onDrop(of: [.url, .plainText], delegate: TabDropDelegate(target: nil, instance: selection.instance, store: store))
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
