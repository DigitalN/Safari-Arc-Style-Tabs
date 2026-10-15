import AppKit
import os.log
import Observation

/// Everything the sidebar shows: Safari's windows and tabs (from the extension), the
/// user's bookmarks, and the custom names given to tabs.
@Observable
final class TabStore {
    struct WindowSelection: Equatable {
        let instance: String
        let window: BrowserWindow
    }

    private(set) var snapshots: [String: Snapshot] = [:] {
        didSet { currentWindowCache = nil; bookmarkMatchCache = nil }
    }
    private(set) var lastMessageAt: Date?
    private(set) var bookmarks: [Bookmark] = [] {
        didSet { libraryCache = nil; bookmarkMatchCache = nil }
    }
    private(set) var customNames: [TabKey: CustomName] = [:]
    private(set) var bookmarkLinks: [UUID: TabKey] = [:] {
        didSet { bookmarkMatchCache = nil }
    }

    private(set) var folderState = FolderState() {
        didSet { libraryCache = nil }
    }
    private(set) var spaceState = SpaceState() {
        didSet { bookmarkMatchCache = nil }
    }
    private(set) var arcMigration = ArcMigrationState()
    private(set) var arcRestoreRunning = false
    private(set) var arcRestoreMessage: String?
    @ObservationIgnored private var arcRestoreDestinations: [String: ArcImportDestination] = [:]
    @ObservationIgnored private var arcRestoreTimeout: DispatchWorkItem?
    var isEditingSpace = false
    private struct PendingSpaceCreate {
        var spaceID: UUID
        let at: Date
        let privateWindow: Bool
        let profile: String?
    }
    @ObservationIgnored private var pendingSpaceCreates: [String: PendingSpaceCreate] = [:]
    @ObservationIgnored private var rememberedTabs: [String: [UUID: Int]] = [:]
    @ObservationIgnored private var expectedSpaceActivation: TabKey?
    /// Empty spaces keep Safari's current page without adopting its space on each
    /// snapshot. A different active tab or window resumes normal Safari following.
    private struct RetainedBackgroundTab {
        var spaceID: UUID
        var windowKey: String
        var tab: TabKey
    }
    @ObservationIgnored private var retainedBackgroundTab: RetainedBackgroundTab?
    @ObservationIgnored private var lastObservedWindow: String?
    @ObservationIgnored private var persistenceURL: URL

    private struct WindowCache { var selection: WindowSelection? }
    private struct BookmarkMatchCache {
        var selection: WindowSelection
        var matches: [UUID: BrowserTab]
    }
    @ObservationIgnored private var currentWindowCache: WindowCache?
    @ObservationIgnored private var libraryCache: PinnedLibraryIndex?
    @ObservationIgnored private var bookmarkMatchCache: BookmarkMatchCache?

    private var library: PinnedLibraryIndex {
        // Keep dependencies registered even on cache hits, so SwiftUI still observes
        // changes. Cache storage itself must not publish mutations during rendering.
        _ = bookmarks; _ = folderState
        if let libraryCache { return libraryCache }
        let index = PinnedLibraryIndex(bookmarks: bookmarks, state: folderState)
        libraryCache = index
        return index
    }

    var renaming: RenameTarget?

    /// Hints from SafariTracker, used to pick the window the sidebar is docked to.
    var safariIsFrontmost = false
    var dockedWindowTitle: String? {
        didSet {
            if dockedWindowTitle != oldValue {
                currentWindowCache = nil
                requestSnapshotIfUnknown(title: dockedWindowTitle)
                if let selection = currentWindow, let snapshot = snapshots[selection.instance] {
                    followSafariSelection(snapshot, previous: snapshot)
                    scheduleSave()
                }
            }
        }
    }
    @ObservationIgnored private var lastSnapshotRequest = Date.distantPast

    @ObservationIgnored var sendCommand: (([String: Any]) -> Void)?
    @ObservationIgnored var onOpenArcImport: (() -> Void)?
    @ObservationIgnored var onToggleSidebar: (() -> Void)?
    @ObservationIgnored var onRenameStateChanged: ((Bool) -> Void)?
    @ObservationIgnored var onOpenAddressBar: (() -> Void)?

    /// Names whose tab ids are gone (Safari restarted), keyed by URL so they can be
    /// given back to the restored tabs.
    @ObservationIgnored private var orphanNames: [String: String] = [:]
    @ObservationIgnored private var pendingBookmarkOpens: [String: (bookmark: UUID, at: Date)] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// When the last tab switch was requested, to log how long Safari took to confirm it.
    @ObservationIgnored private var pendingActivation: (key: TabKey, at: Date)?
    @ObservationIgnored private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "store")

    init(stateURL: URL? = nil) {
        persistenceURL = stateURL ?? Self.stateURL
        load()
    }

    // MARK: - Messages from the extension

    func handleMessage(type: String, payload: Data, object: [String: Any]) -> [String: Any] {
        lastMessageAt = Date()
        switch type {
        case "snapshot":
            do {
                apply(try JSONDecoder().decode(Snapshot.self, from: payload))
            } catch {
                NSLog("Side Tabs: bad snapshot: \(error)")
            }
            return [:]

        case "hello":
            return ["needSnapshot": true]

        case "heartbeat":
            // The extension reports the last snapshot it delivered; ask again if we missed one.
            let instance = object["instance"] as? String ?? ""
            let seq = object["seq"] as? Int ?? 0
            let applied = snapshots[instance]?.seq ?? -1
            // Website permission changes do not always produce a tabs API event.
            return ["needSnapshot": applied < seq || seq == 0 || lacksWebsiteAccess]

        case "toggleSidebar":
            onToggleSidebar?()
            return [:]

        case "migrationCreated", "migrationAttention":
            handleArcRestoreReply(type: type, object: object)
            return [:]

        case "created":
            if let requestId = object["requestId"] as? String,
               let instance = object["instance"] as? String,
               let tabId = object["tabId"] as? Int,
               let pending = pendingSpaceCreates.removeValue(forKey: requestId) {
                let key = TabKey(instance: instance, tabId: tabId)
                // The created reply can arrive before or after the first snapshot.
                if spaceState.spaceID(for: key) == nil {
                    spaceState.memberships.append(.init(key: key, spaceID: pending.spaceID,
                        url: nil, windowIndex: 0, privateWindow: pending.privateWindow, profile: pending.profile))
                } else {
                    spaceState.assign(key, to: pending.spaceID)
                }
                if pending.spaceID != selectedSpace.id, let selection = currentWindow {
                    activateSelectedSpace(in: selection)
                }
                scheduleSave()
            }
            if let requestId = object["requestId"] as? String,
               let instance = object["instance"] as? String,
               let tabId = object["tabId"] as? Int,
               let pending = pendingBookmarkOpens.removeValue(forKey: requestId) {
                bookmarkLinks[pending.bookmark] = TabKey(instance: instance, tabId: tabId)
            }
            return [:]

        default:
            return [:]
        }
    }

    private func apply(_ snapshot: Snapshot) {
        if let existing = snapshots[snapshot.instance], existing.seq > snapshot.seq {
            return
        }
        pendingSpaceCreates = pendingSpaceCreates.filter { Date().timeIntervalSince($0.value.at) < 60 }
        let previous = snapshots[snapshot.instance]
        let isNewInstance = previous == nil
        snapshots[snapshot.instance] = snapshot
        let tabCounts = snapshot.windows.map { String($0.tabs.count) }.joined(separator: "+")
        log.info("snapshot \(snapshot.seq) from \(snapshot.instance.prefix(8), privacy: .public): \(snapshot.windows.count) windows, tabs \(tabCounts, privacy: .public), focused \(snapshot.focusedWindowId ?? -1)")
        if isNewInstance {
            orphanNamesOfDeadInstances()
        }
        let priorSpaces = spaceState
        spaceState.reconcile(snapshot, liveInstances: Set(snapshots.keys))
        followSafariSelection(snapshot, previous: previous)
        if priorSpaces != spaceState { scheduleSave() }
        reconcileNames(with: snapshot)
        pruneBookmarkLinks()

        if let pending = pendingActivation, pending.key.instance == snapshot.instance,
           snapshot.windows.contains(where: { $0.tabs.contains { $0.id == pending.key.tabId && $0.active } }) {
            pendingActivation = nil
            let milliseconds = Int(Date().timeIntervalSince(pending.at) * 1000)
            log.notice("tab switch confirmed by Safari after \(milliseconds) ms")
        }
    }

    /// Safari quit: forget its tabs but remember names by URL for next launch.
    func safariDidTerminate() {
        snapshots.removeAll()
        orphanNamesOfDeadInstances()
        bookmarkLinks.removeAll()
        pendingBookmarkOpens.removeAll()
        renaming = nil
        rememberedTabs.removeAll()
        expectedSpaceActivation = nil
        retainedBackgroundTab = nil
        lastObservedWindow = nil
        pendingSpaceCreates.removeAll()
        scheduleSave()
    }

    func requestSnapshot() {
        lastSnapshotRequest = Date()
        sendCommand?(["action": "snapshot"])
    }

    /// Safari doesn't always tell extensions about windows it restores (Reopen Last Closed
    /// Window, relaunch), so when the docked window matches nothing we know, ask again.
    private func requestSnapshotIfUnknown(title: String?) {
        guard let title, !title.isEmpty else { return }
        let known = snapshots.values.contains { snapshot in
            snapshot.windows.contains { activeTitle(of: $0) == title }
        }
        guard !known, Date().timeIntervalSince(lastSnapshotRequest) > 0.5 else { return }
        requestSnapshot()
        // Titles can lag behind while a page loads; check once more shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.dockedWindowTitle == title else { return }
            let stillUnknown = !self.snapshots.values.contains { snapshot in
                snapshot.windows.contains { self.activeTitle(of: $0) == title }
            }
            if stillUnknown {
                self.requestSnapshot()
            }
        }
    }

    // MARK: - Window selection

    var hasData: Bool { !snapshots.isEmpty }

    var isConnected: Bool {
        guard let lastMessageAt else { return false }
        return Date().timeIntervalSince(lastMessageAt) < 60
    }

    /// True when Safari reports tabs but no URLs or titles, which means the extension
    /// hasn't been allowed on websites yet.
    var lacksWebsiteAccess: Bool {
        let tabs = snapshots.values.flatMap { $0.windows.flatMap(\.tabs) }
        return !tabs.isEmpty && tabs.allSatisfy { $0.url == nil && $0.title == nil }
    }

    /// The Safari window the sidebar shows: the one most recently focused, cross-checked
    /// against the title of the window the panel is docked to.
    var currentWindow: WindowSelection? {
        _ = snapshots; _ = dockedWindowTitle
        if let currentWindowCache { return currentWindowCache.selection }
        let selection = findCurrentWindow()
        currentWindowCache = WindowCache(selection: selection)
        return selection
    }

    private func findCurrentWindow() -> WindowSelection? {
        let ordered = snapshots.values.sorted { $0.focusChangedAt > $1.focusChangedAt }
        var best: WindowSelection?
        for snapshot in ordered {
            let focused = (snapshot.focusedWindowId ?? -1) >= 0 ? snapshot.focusedWindowId : snapshot.lastFocusedWindowId
            if let focused, let window = snapshot.windows.first(where: { $0.id == focused }) {
                best = WindowSelection(instance: snapshot.instance, window: window)
                break
            }
        }
        if best == nil, let snapshot = ordered.first(where: { !$0.windows.isEmpty }) {
            best = WindowSelection(instance: snapshot.instance, window: snapshot.windows[0])
        }

        if let title = dockedWindowTitle, !title.isEmpty, let current = best, activeTitle(of: current.window) != title {
            let matches = snapshots.values.flatMap { snapshot in
                snapshot.windows
                    .filter { activeTitle(of: $0) == title }
                    .map { WindowSelection(instance: snapshot.instance, window: $0) }
            }
            if matches.count == 1 {
                return matches[0]
            }
        }
        return best
    }

    private func activeTitle(of window: BrowserWindow) -> String? {
        window.tabs.first(where: \.active)?.title
    }

    // MARK: - Tab names

    func displayTitle(for tab: BrowserTab, instance: String) -> String {
        if let custom = customNames[TabKey(instance: instance, tabId: tab.id)]?.name {
            return custom
        }
        return pageTitle(for: tab)
    }

    func pageTitle(for tab: BrowserTab) -> String {
        if let title = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let host = tab.host, !host.isEmpty {
            return host
        }
        if let url = tab.url, !url.isEmpty, !url.hasPrefix("about:"), !url.hasPrefix("favorites:") {
            return url
        }
        return "New Tab"
    }

    func hasCustomName(_ key: TabKey) -> Bool {
        customNames[key] != nil
    }

    func resetName(_ key: TabKey) {
        customNames[key] = nil
        scheduleSave()
    }

    func beginRename(_ target: RenameTarget) {
        renaming = target
        onRenameStateChanged?(true)
    }

    func commitRename(_ text: String) {
        guard let target = renaming else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .tab(let key):
            let tab = tab(for: key)
            if name.isEmpty || name == tab.map(pageTitle(for:)) {
                customNames[key] = nil
            } else {
                customNames[key] = CustomName(name: name, url: tab?.url)
            }
        case .folder(let id):
            if !name.isEmpty, let index = folderState.folders.firstIndex(where: { $0.id == id }) {
                folderState.folders[index].name = name
            }
        case .bookmark(let id):
            if !name.isEmpty, let index = bookmarks.firstIndex(where: { $0.id == id }) {
                bookmarks[index].title = name
            }
        }
        renaming = nil
        scheduleSave()
        onRenameStateChanged?(false)
    }

    func cancelRename() {
        guard renaming != nil else { return }
        renaming = nil
        onRenameStateChanged?(false)
    }

    private func reconcileNames(with snapshot: Snapshot) {
        let tabs = snapshot.windows.flatMap(\.tabs)
        let tabsByID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names = customNames

        for (key, custom) in names where key.instance == snapshot.instance {
            if let tab = tabsByID[key.tabId] {
                if custom.url != tab.url, tab.url != nil {
                    names[key]?.url = tab.url
                }
            } else {
                names[key] = nil
            }
        }

        if !orphanNames.isEmpty {
            for tab in tabs {
                let key = TabKey(instance: snapshot.instance, tabId: tab.id)
                guard names[key] == nil, let url = tab.url, let name = orphanNames.removeValue(forKey: url) else { continue }
                names[key] = CustomName(name: name, url: url)
            }
        }

        if names != customNames {
            customNames = names
            scheduleSave()
        }
    }

    private func orphanNamesOfDeadInstances() {
        let live = Set(snapshots.keys)
        var names = customNames
        for (key, custom) in customNames where !live.contains(key.instance) {
            if let url = custom.url {
                orphanNames[url] = custom.name
            }
            names[key] = nil
        }
        if names != customNames {
            customNames = names
            scheduleSave()
        }
    }

    // MARK: - Address bar

    var activeTab: (tab: BrowserTab, instance: String)? {
        guard let selection = currentWindow, let tab = selection.window.tabs.first(where: \.active) else { return nil }
        return (tab, selection.instance)
    }

    func reloadActiveTab() {
        guard let active = activeTab else { return }
        reload(active.tab, instance: active.instance)
    }

    /// Opens Safari's own address bar, which has its full autocomplete.
    func openAddressBar() {
        onOpenAddressBar?()
    }

    // MARK: - Tab commands

    func tab(for key: TabKey) -> BrowserTab? {
        snapshots[key.instance]?.windows.lazy.flatMap(\.tabs).first { $0.id == key.tabId }
    }

    func activate(_ tab: BrowserTab, instance: String) {
        let key = TabKey(instance: instance, tabId: tab.id)
        if let id = spaceState.spaceID(for: key) {
            spaceState.selectedID = id
            rememberedTabs[windowKey(instance: instance, windowID: tab.windowId), default: [:]][id] = tab.id
            scheduleSave()
        }
        pendingActivation = (key, Date())
        mutateWindow(instance: instance, windowId: tab.windowId) { window in
            for index in window.tabs.indices {
                window.tabs[index].active = window.tabs[index].id == tab.id
            }
        }
        if let selection = currentWindow { revealPinnedTab(tab.id, in: selection) }
        send(["action": "activate", "tabId": tab.id], to: instance)
    }

    func close(_ tabs: [BrowserTab], instance: String) {
        guard let windowId = tabs.first?.windowId else { return }
        let ids = Set(tabs.map(\.id))
        let closesActive = window(instance: instance, id: windowId)?.tabs.contains { ids.contains($0.id) && $0.active } == true
        mutateWindow(instance: instance, windowId: windowId) { window in
            let closingActive = window.tabs.contains { ids.contains($0.id) && $0.active }
            if closingActive, let activeIndex = window.tabs.firstIndex(where: \.active) {
                // Safari usually selects the tab to the right; guess the same so the highlight doesn't blink.
                let remaining = window.tabs.enumerated().filter { !ids.contains($0.element.id) }
                if let next = remaining.first(where: { $0.offset > activeIndex }) ?? remaining.last {
                    window.tabs[next.offset].active = true
                }
            }
            window.tabs.removeAll { ids.contains($0.id) }
        }
        send(["action": "close", "tabIds": Array(ids)], to: instance)
        if closesActive, let remaining = window(instance: instance, id: windowId) {
            activateSelectedSpace(in: WindowSelection(instance: instance, window: remaining))
        }
    }

    func closeOtherTabs(than tab: BrowserTab, instance: String) {
        guard let window = window(instance: instance, id: tab.windowId) else { return }
        let selection = WindowSelection(instance: instance, window: window)
        close(displayedTabs(in: selection).filter { $0.id != tab.id && !$0.pinned }, instance: instance)
    }

    func closeTabsBelow(_ tab: BrowserTab, instance: String) {
        guard let window = window(instance: instance, id: tab.windowId) else { return }
        let visible = displayedTabs(in: WindowSelection(instance: instance, window: window))
        guard let index = visible.firstIndex(where: { $0.id == tab.id }) else { return }
        close(Array(visible.dropFirst(index + 1)).filter { !$0.pinned }, instance: instance)
    }

    func newTab(url: String? = nil) {
        guard let selection = currentWindow else {
            openInSafari(url ?? "")
            return
        }
        var command: [String: Any] = ["action": "create", "windowId": selection.window.id]
        if let url {
            command["url"] = url
        }
        command["requestId"] = spaceCreateRequest(for: selectedSpace.id)
        send(command, to: selection.instance)
    }

    func duplicate(_ tab: BrowserTab, instance: String) {
        send(["action": "duplicate", "tabId": tab.id, "requestId": spaceCreateRequest(for: spaceState.spaceID(for: TabKey(instance: instance, tabId: tab.id)) ?? selectedSpace.id)], to: instance)
    }

    func reload(_ tab: BrowserTab, instance: String) {
        send(["action": "reload", "tabId": tab.id], to: instance)
    }

    func setMuted(_ muted: Bool, tab: BrowserTab, instance: String) {
        send(["action": "mute", "tabId": tab.id, "muted": muted], to: instance)
    }

    func copyLink(_ url: String?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// Moves a tab to `index` (its position once moved) and tells Safari.
    func moveTab(_ tab: BrowserTab, instance: String, to index: Int, showBookmarks: Bool = true) {
        guard let fullWindow = window(instance: instance, id: tab.windowId) else { return }
        let visible = displayedTabs(in: WindowSelection(instance: instance, window: fullWindow), showBookmarks: showBookmarks)
        guard visible.contains(where: { $0.id == tab.id }) else { return }
        let slot = min(max(index, 0), visible.count - 1)
        var destination = visible[slot].index
        mutateWindow(instance: instance, windowId: tab.windowId) { window in
            guard let from = window.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            let moved = window.tabs.remove(at: from)
            destination = min(max(destination, 0), window.tabs.count)
            window.tabs.insert(moved, at: destination)
            for position in window.tabs.indices {
                window.tabs[position].index = position
            }
        }
        guard destination != tab.index else { return }
        send(["action": "move", "tabId": tab.id, "index": destination], to: instance)
    }

    private func window(instance: String, id: Int) -> BrowserWindow? {
        snapshots[instance]?.windows.first { $0.id == id }
    }

    private func mutateWindow(instance: String, windowId: Int, _ body: (inout BrowserWindow) -> Void) {
        guard var snapshot = snapshots[instance],
              let index = snapshot.windows.firstIndex(where: { $0.id == windowId }) else { return }
        body(&snapshot.windows[index])
        snapshots[instance] = snapshot
    }

    private func send(_ command: [String: Any], to instance: String) {
        var command = command
        command["instance"] = instance
        sendCommand?(command)
    }

    private func openInSafari(_ url: String) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
        let urls = URL(string: url).map { [$0] } ?? []
        NSWorkspace.shared.open(urls, withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Bookmarks

    /// A physical tab has one sidebar row. Explicit links survive navigation; URL
    /// fallback consumes one tab per bookmark so extra copies stay ordinary tabs.
    private func bookmarkTabs(in selection: WindowSelection) -> [UUID: BrowserTab] {
        _ = bookmarks; _ = bookmarkLinks; _ = spaceState
        if let cache = bookmarkMatchCache, cache.selection == selection { return cache.matches }
        let visible = bookmarks.filter { bookmark in
            bookmark.spaceID == selectedSpace.id || (bookmark.spaceID == nil &&
                (bookmark.arcProfileID == nil || bookmark.arcProfileID == selectedSpace.arcProfileID))
        }
        var result: [UUID: BrowserTab] = [:]
        var claimed = Set<Int>()
        let ownership = Dictionary(spaceState.memberships.map { ($0.key, $0.spaceID) }, uniquingKeysWith: { first, _ in first })
        let tabsByID = Dictionary(selection.window.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func belongs(_ tab: BrowserTab, to bookmark: Bookmark) -> Bool {
            bookmark.spaceID == nil || ownership[TabKey(instance: selection.instance, tabId: tab.id)] == bookmark.spaceID
        }
        for bookmark in visible {
            if let key = bookmarkLinks[bookmark.id], key.instance == selection.instance,
               let tab = tabsByID[key.tabId],
               belongs(tab, to: bookmark), claimed.insert(tab.id).inserted {
                result[bookmark.id] = tab
            }
        }
        // Normalize each URL once. Active-first queues retain the prior matching
        // order, while consuming duplicates once instead of rescanning all tabs.
        var all: [String: [BrowserTab]] = [:], scoped: [String: [BrowserTab]] = [:]
        let ordered = selection.window.tabs.filter(\.active) + selection.window.tabs.filter { !$0.active }
        for tab in ordered where !claimed.contains(tab.id) {
            guard let url = tab.url?.comparableURL else { continue }
            all[url, default: []].append(tab)
            if ownership[TabKey(instance: selection.instance, tabId: tab.id)] == selectedSpace.id {
                scoped[url, default: []].append(tab)
            }
        }
        var allOffsets: [String: Int] = [:], scopedOffsets: [String: Int] = [:]
        func take(_ queue: [BrowserTab], offset: inout Int) -> BrowserTab? {
            while offset < queue.count {
                let tab = queue[offset]; offset += 1
                if !claimed.contains(tab.id) { return tab }
            }
            return nil
        }
        let urls = library.comparableURLs
        for bookmark in visible where result[bookmark.id] == nil {
            let target = urls[bookmark.id] ?? bookmark.url.comparableURL
            let tab = bookmark.spaceID == nil
                ? take(all[target] ?? [], offset: &allOffsets[target, default: 0])
                : take(scoped[target] ?? [], offset: &scopedOffsets[target, default: 0])
            if let tab {
                result[bookmark.id] = tab
                claimed.insert(tab.id)
            }
        }
        bookmarkMatchCache = BookmarkMatchCache(selection: selection, matches: result)
        return result
    }

    /// All tabs assigned to this space remain available to switching and persistence.
    /// Only the lower, ordinary-tab list excludes tabs already represented above it.
    func displayedTabs(in selection: WindowSelection, showBookmarks: Bool = true) -> [BrowserTab] {
        let all = tabs(in: selection)
        guard showBookmarks else { return all }
        let represented = Set(bookmarkTabs(in: selection).values.map(\.id))
        return all.filter { !represented.contains($0.id) }
    }

    func openTab(for bookmark: Bookmark) -> BrowserTab? {
        currentWindow.flatMap { bookmarkTabs(in: $0)[bookmark.id] }
    }

    private func revealPinnedTab(_ tabID: Int, in selection: WindowSelection) {
        guard let id = bookmarkTabs(in: selection).first(where: { $0.value.id == tabID })?.key,
              let bookmark = bookmark(id), bookmark.spaceID == selectedSpace.id else { return }
        var parent = bookmark.folderID
        var visited = Set<UUID>()
        var changed = false
        while let id = parent, visited.insert(id).inserted, let index = folderState.folders.firstIndex(where: { $0.id == id }) {
            if !folderState.folders[index].isExpanded { folderState.folders[index].isExpanded = true; changed = true }
            parent = folderState.folders[index].parentID
        }
        if changed { scheduleSave() }
    }

    func open(_ bookmark: Bookmark, inNewTab: Bool = false) {
        guard let selection = currentWindow else {
            openInSafari(bookmark.url)
            return
        }
        if !inNewTab, let tab = openTab(for: bookmark) {
            bookmarkLinks[bookmark.id] = TabKey(instance: selection.instance, tabId: tab.id)
            if bookmark.spaceID == nil {
                spaceState.assign(TabKey(instance: selection.instance, tabId: tab.id), to: selectedSpace.id)
            }
            activate(tab, instance: selection.instance)
            return
        }
        // A quick second click arrives before Safari reports the new tab; don't open two.
        pendingBookmarkOpens = pendingBookmarkOpens.filter { Date().timeIntervalSince($0.value.at) < 2 }
        if !inNewTab, pendingBookmarkOpens.values.contains(where: { $0.bookmark == bookmark.id }) {
            return
        }
        let requestId = spaceCreateRequest(for: bookmark.spaceID ?? selectedSpace.id)
        pendingBookmarkOpens[requestId] = (bookmark.id, Date())
        send([
            "action": "create",
            "windowId": selection.window.id,
            "url": bookmark.url,
            "requestId": requestId,
        ], to: selection.instance)
    }

    func addBookmark(from tab: BrowserTab, instance: String, at index: Int? = nil, folderID: UUID? = nil) {
        guard let url = tab.url, !url.isEmpty else { return }
        let bookmark = Bookmark(
            title: displayTitle(for: tab, instance: instance),
            url: url,
            faviconURL: tab.favIconUrl,
            spaceID: selectedSpace.id,
            folderID: folderID
        )
        insert(bookmark, at: index)
        bookmarkLinks[bookmark.id] = TabKey(instance: instance, tabId: tab.id)
    }

    func addBookmarkForCurrentTab() {
        guard let selection = currentWindow, let tab = selection.window.tabs.first(where: \.active) else { return }
        addBookmark(from: tab, instance: selection.instance)
    }

    func addBookmark(url: URL, at index: Int? = nil, folderID: UUID? = nil) {
        guard let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else { return }
        insert(Bookmark(title: url.host() ?? url.absoluteString, url: url.absoluteString, spaceID: selectedSpace.id, folderID: folderID), at: index)
    }

    private func insert(_ bookmark: Bookmark, at index: Int?) {
        var bookmark = bookmark
        if let id = bookmark.folderID, folder(id)?.spaceID != bookmark.spaceID { bookmark.folderID = nil }
        bookmarks.append(bookmark)
        movePinnedItem(.bookmark(bookmark.id), to: bookmark.folderID, at: index)
        scheduleSave()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        bookmarkLinks[bookmark.id] = nil
        folderState.order.removeAll { $0 == .bookmark(bookmark.id) }
        scheduleSave()
    }

    func replaceBookmarkWithCurrentPage(_ bookmark: Bookmark) {
        guard let selection = currentWindow,
              let tab = selection.window.tabs.first(where: \.active),
              let url = tab.url,
              let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index].url = url
        bookmarks[index].faviconURL = tab.favIconUrl
        bookmarkLinks[bookmark.id] = TabKey(instance: selection.instance, tabId: tab.id)
        scheduleSave()
    }

    /// Moves a bookmark to `index` (its position once moved).
    func moveBookmark(_ id: UUID, to index: Int) {
        guard let from = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        if bookmarks[from].spaceID != nil {
            movePinnedItem(.bookmark(id), to: bookmarks[from].folderID, at: index)
            return
        }
        let bookmark = bookmarks.remove(at: from)
        let peers = bookmarks.filter { $0.spaceID == bookmark.spaceID }
        let slot = min(max(index, 0), peers.count)
        let destination = slot < peers.count ? bookmarks.firstIndex(where: { $0.id == peers[slot].id })! : bookmarks.count
        bookmarks.insert(bookmark, at: destination)
        scheduleSave()
    }

    private func pruneBookmarkLinks() {
        let stale = bookmarkLinks.filter { tab(for: $0.value) == nil }.map(\.key)
        for id in stale {
            bookmarkLinks[id] = nil
        }
    }

    // MARK: - Persistence

    private struct SavedName: Codable {
        let instance: String
        let tabId: Int
        let name: CustomName
    }

    private struct SavedState: Codable {
        var bookmarks: [Bookmark]
        var names: [SavedName]
        var orphanNames: [String: String]
        var spaces: SpaceState?
        var folders: FolderState?
        var arcMigration: ArcMigrationState?
    }

    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Side Tabs", directoryHint: .isDirectory).appending(path: "state.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        arcMigration = state.arcMigration ?? ArcMigrationState()
        bookmarks = state.bookmarks
        spaceState = state.spaces ?? SpaceState()
        spaceState.normalize()
        for index in bookmarks.indices {
            if let id = bookmarks[index].spaceID, !spaceState.spaces.contains(where: { $0.id == id }) {
                bookmarks[index].spaceID = spaceState.spaces[0].id
            }
        }
        folderState = state.folders ?? FolderState()
        folderState.normalize(bookmarks: &bookmarks, spaces: spaces)
        orphanNames = state.orphanNames
        customNames = Dictionary(
            state.names.map { (TabKey(instance: $0.instance, tabId: $0.tabId), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func encodedState() throws -> Data {
        let state = SavedState(
            bookmarks: bookmarks,
            names: customNames.map { SavedName(instance: $0.key.instance, tabId: $0.key.tabId, name: $0.value) },
            orphanNames: orphanNames,
            spaces: spaceState.persistentCopy,
            folders: folderState,
            arcMigration: arcMigration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    private func persistState() throws {
        let url = persistenceURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodedState().write(to: url, options: .atomic)
    }

    func save() {
        do {
            try persistState()
        } catch {
            NSLog("Side Tabs: could not save state: \(error)")
        }
    }
}

extension TabStore {
    var spaces: [BrowserSpace] { spaceState.spaces }
    var selectedSpace: BrowserSpace { spaceState.selected }
    var favorites: [Bookmark] { bookmarks.filter { $0.spaceID == nil && ($0.arcProfileID == nil || $0.arcProfileID == selectedSpace.arcProfileID) } }
    var pinnedBookmarks: [Bookmark] { bookmarks.filter { $0.spaceID == selectedSpace.id } }

    func tabs(in selection: WindowSelection) -> [BrowserTab] {
        let spaceID = selectedSpace.id
        var seen = Set<TabKey>(), keys = Set<TabKey>()
        for member in spaceState.memberships where seen.insert(member.key).inserted && member.spaceID == spaceID {
            keys.insert(member.key)
        }
        return selection.window.tabs.filter { keys.contains(TabKey(instance: selection.instance, tabId: $0.id)) }
    }

    private func windowKey(instance: String, windowID: Int) -> String { "\(instance):\(windowID)" }

    func selectSpace(_ id: UUID) {
        guard id != selectedSpace.id, spaces.contains(where: { $0.id == id }),
              renaming == nil, !isEditingSpace else { return }
        spaceState.selectedID = id
        scheduleSave()
        if let selection = currentWindow { activateSelectedSpace(in: selection) }
    }

    func switchSpace(direction: Int) {
        guard let index = spaces.firstIndex(where: { $0.id == selectedSpace.id }) else { return }
        let next = index + direction
        guard spaces.indices.contains(next) else { return }
        selectSpace(spaces[next].id)
    }

    @discardableResult func createSpace() -> BrowserSpace {
        var space = BrowserSpace()
        space.name = "Space \(spaces.count + 1)"
        space.icon = BrowserSpace.icons[spaces.count % BrowserSpace.icons.count]
        space.theme = BrowserSpace.themes[spaces.count % BrowserSpace.themes.count]
        spaceState.spaces.append(space)
        selectSpace(space.id)
        scheduleSave()
        return space
    }

    func updateSpace(_ space: BrowserSpace) {
        guard let index = spaceState.spaces.firstIndex(where: { $0.id == space.id }) else { return }
        var edited = space
        edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.name.isEmpty else { return }
        if let raw = edited.emoji {
            guard let emoji = BrowserSpace.normalizedEmoji(raw) else { return }
            edited.emoji = emoji
        }
        spaceState.spaces[index] = edited
        scheduleSave()
    }

    func deleteSpace(_ id: UUID) {
        guard let destination = spaceState.remove(id) else { return }
        for index in folderState.folders.indices where folderState.folders[index].spaceID == id {
            folderState.folders[index].spaceID = destination
        }
        for index in bookmarks.indices where bookmarks[index].spaceID == id {
            bookmarks[index].spaceID = destination
        }
        for request in Array(pendingSpaceCreates.keys) where pendingSpaceCreates[request]?.spaceID == id {
            pendingSpaceCreates[request]?.spaceID = destination
        }
        scheduleSave()
        if let selection = currentWindow { activateSelectedSpace(in: selection) }
    }

    func moveTabToSpace(_ tab: BrowserTab, instance: String, spaceID: UUID) {
        let key = TabKey(instance: instance, tabId: tab.id)
        spaceState.assign(key, to: spaceID)
        if tab.active, let selection = currentWindow {
            activateSelectedSpace(in: selection)
        }
        scheduleSave()
    }

    func moveBookmarkToSpace(_ bookmark: Bookmark, spaceID: UUID?) {
        guard spaceID == nil || spaces.contains(where: { $0.id == spaceID }),
              let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index].spaceID = spaceID
        bookmarks[index].folderID = nil
        if let spaceID, let key = bookmarkLinks[bookmark.id], spaceState.spaceID(for: key) != spaceID {
            bookmarkLinks[bookmark.id] = nil
        }
        folderState.order.removeAll { $0 == .bookmark(bookmark.id) }
        scheduleSave()
    }

    private func spaceCreateRequest(for id: UUID) -> String {
        pendingSpaceCreates = pendingSpaceCreates.filter { Date().timeIntervalSince($0.value.at) < 60 }
        let request = UUID().uuidString
        let selection = currentWindow
        pendingSpaceCreates[request] = PendingSpaceCreate(spaceID: id, at: Date(),
            privateWindow: selection?.window.incognito ?? true,
            profile: selection.flatMap { snapshots[$0.instance]?.profile })
        return request
    }

    private func activateSelectedSpace(in selection: WindowSelection) {
        let candidates = tabs(in: selection)
        let remembered = rememberedTabs[windowKey(instance: selection.instance, windowID: selection.window.id)]?[selectedSpace.id]
        if let tab = candidates.first(where: { $0.id == remembered }) ?? candidates.first(where: \.active) ?? candidates.first {
            retainedBackgroundTab = nil
            let key = TabKey(instance: selection.instance, tabId: tab.id)
            expectedSpaceActivation = key
            activate(tab, instance: selection.instance)
        } else {
            // Switching is organizational. Only explicit New Tab / Open actions
            // create Safari tabs, even when this space is empty in this window.
            retainedBackgroundTab = selection.window.tabs.first(where: \.active).map {
                RetainedBackgroundTab(spaceID: selectedSpace.id,
                    windowKey: windowKey(instance: selection.instance, windowID: selection.window.id),
                    tab: TabKey(instance: selection.instance, tabId: $0.id))
            }
        }
    }

    private func followSafariSelection(_ snapshot: Snapshot, previous: Snapshot?) {
        guard let selection = currentWindow, selection.instance == snapshot.instance,
              let active = selection.window.tabs.first(where: \.active) else { return }
        let key = TabKey(instance: snapshot.instance, tabId: active.id)
        if let pending = pendingActivation, Date().timeIntervalSince(pending.at) > 2 {
            expectedSpaceActivation = nil
        }
        if let expected = expectedSpaceActivation {
            if key == expected { expectedSpaceActivation = nil }
            else if tab(for: expected) != nil { return }
            else { expectedSpaceActivation = nil }
        }
        let priorActive = previous?.windows.first(where: { $0.id == active.windowId })?.tabs.first(where: \.active)?.id
        let currentWindowKey = windowKey(instance: snapshot.instance, windowID: active.windowId)
        let changedWindow = currentWindowKey != lastObservedWindow
        lastObservedWindow = currentWindowKey
        if let retained = retainedBackgroundTab, retained.spaceID == selectedSpace.id,
           retained.windowKey == currentWindowKey, retained.tab == key {
            return
        }
        retainedBackgroundTab = nil
        guard previous == nil || priorActive != active.id || changedWindow else { return }
        if let id = spaceState.spaceID(for: key) {
            // A pending new tab belongs to the space that requested it, even if the
            // snapshot races its created reply. Do not bounce back to the old space.
            if pendingSpaceCreates.values.contains(where: { Date().timeIntervalSince($0.at) < 2 }) && id != selectedSpace.id { return }
            spaceState.selectedID = id
            rememberedTabs[windowKey(instance: snapshot.instance, windowID: active.windowId), default: [:]][id] = active.id
            revealPinnedTab(active.id, in: selection)
        }
    }
}

extension TabStore {
    func reorderSelectedSpace(direction: Int) {
        guard let index = spaceState.spaces.firstIndex(where: { $0.id == selectedSpace.id }),
              spaceState.spaces.indices.contains(index + direction) else { return }
        spaceState.spaces.swapAt(index, index + direction)
        scheduleSave()
    }
}


// MARK: - Pinned folders
extension TabStore {
    var folders: [PinnedFolder] { folderState.folders }
    func folder(_ id: UUID) -> PinnedFolder? { library.folders[id] }
    func bookmark(_ id: UUID) -> Bookmark? { library.bookmarks[id] }
    func pinnedChildren(of parentID: UUID? = nil, spaceID: UUID? = nil) -> [PinnedItem] {
        library.children[.init(spaceID: spaceID ?? selectedSpace.id, folderID: parentID)] ?? []
    }
    func parentFolder(of item: PinnedItem) -> UUID? {
        switch item {
        case .folder(let id): folder(id)?.parentID
        case .bookmark(let id): bookmark(id)?.folderID
        }
    }
    var visiblePinnedEntries: [PinnedEntry] { pinnedEntries(includeCollapsed: false) }
    func pinnedEntries(includeCollapsed: Bool) -> [PinnedEntry] {
        let index = library
        return (includeCollapsed ? index.allEntries : index.visibleEntries)[selectedSpace.id] ?? []
    }
    func folderPath(_ id: UUID) -> String {
        var names: [String] = []
        var current: UUID? = id
        var seen = Set<UUID>()
        while let next = current, let folder = folder(next), seen.insert(next).inserted {
            names.insert(folder.name, at: 0)
            current = folder.parentID
        }
        return names.joined(separator: " / ")
    }
    @discardableResult func createFolder(parentID: UUID? = nil, name: String = "New Folder") -> PinnedFolder {
        let parent = parentID.flatMap(folder)
        let folder = PinnedFolder(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Folder" : name,
                                  spaceID: parent?.spaceID ?? selectedSpace.id, parentID: parent?.id)
        folderState.folders.append(folder)
        folderState.order.append(.folder(folder.id))
        if let parent { expandFolder(parent.id) }
        scheduleSave()
        return folder
    }
    func toggleFolder(_ id: UUID) {
        guard let index = folderState.folders.firstIndex(where: { $0.id == id }) else { return }
        folderState.folders[index].isExpanded.toggle()
        scheduleSave()
    }
    private func expandFolder(_ id: UUID) {
        if let index = folderState.folders.firstIndex(where: { $0.id == id }) {
            folderState.folders[index].isExpanded = true
        }
    }
    func canMovePinnedItem(_ item: PinnedItem, into destination: UUID?) -> Bool {
        guard let destination else { return true }
        guard folder(destination) != nil else { return false }
        if case .folder(let id) = item { return !folderState.descendants(of: id).contains(destination) }
        return true
    }
    /// Reparent/reorder a pin or an entire folder subtree. Cycles are rejected.
    func movePinnedItem(_ item: PinnedItem, to parentID: UUID?, at index: Int? = nil, spaceID: UUID? = nil) {
        guard canMovePinnedItem(item, into: parentID) else { return }
        let owner = parentID.flatMap(folder)?.spaceID ?? spaceID ?? selectedSpace.id
        guard spaces.contains(where: { $0.id == owner }) else { return }
        switch item {
        case .folder(let id):
            guard let i = folderState.folders.firstIndex(where: { $0.id == id }) else { return }
            let subtree = folderState.descendants(of: id)
            folderState.folders[i].parentID = parentID
            for i in folderState.folders.indices where subtree.contains(folderState.folders[i].id) {
                folderState.folders[i].spaceID = owner
            }
            for i in bookmarks.indices where bookmarks[i].folderID.map(subtree.contains) == true {
                bookmarks[i].spaceID = owner
                if let key = bookmarkLinks[bookmarks[i].id], spaceState.spaceID(for: key) != owner {
                    bookmarkLinks[bookmarks[i].id] = nil
                }
            }
        case .bookmark(let id):
            guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
            bookmarks[i].folderID = parentID
            bookmarks[i].spaceID = owner
            if let key = bookmarkLinks[id], spaceState.spaceID(for: key) != owner { bookmarkLinks[id] = nil }
        }
        let peers = pinnedChildren(of: parentID, spaceID: owner).filter { $0 != item }
        let slot = min(max(index ?? peers.count, 0), peers.count)
        folderState.order.removeAll { $0 == item }
        if slot < peers.count, let anchor = folderState.order.firstIndex(of: peers[slot]) {
            folderState.order.insert(item, at: anchor)
        } else if let last = peers.last, let anchor = folderState.order.firstIndex(of: last) {
            folderState.order.insert(item, at: anchor + 1)
        } else { folderState.order.append(item) }
        if let parentID { expandFolder(parentID) }
        scheduleSave()
    }
    func reorderPinnedItem(_ item: PinnedItem, direction: Int) {
        let parent = parentFolder(of: item)
        let peers = pinnedChildren(of: parent)
        guard let index = peers.firstIndex(of: item), peers.indices.contains(index + direction) else { return }
        movePinnedItem(item, to: parent, at: index + direction)
    }
    /// Only removes the container. Immediate children take its place in the parent;
    /// nested hierarchies, pinned sites, and all live Safari tabs are retained.
    func removeFolder(_ id: UUID) {
        guard let folder = folder(id) else { return }
        let siblings = pinnedChildren(of: folder.parentID, spaceID: folder.spaceID)
        let position = siblings.firstIndex(of: .folder(id)) ?? siblings.count
        let children = pinnedChildren(of: id, spaceID: folder.spaceID)
        for (offset, child) in children.enumerated() {
            movePinnedItem(child, to: folder.parentID, at: position + offset, spaceID: folder.spaceID)
        }
        folderState.folders.removeAll { $0.id == id }
        folderState.order.removeAll { $0 == .folder(id) }
        if renaming == .folder(id) { cancelRename() }
        scheduleSave()
    }
}

// MARK: - Arc migration (preview never mutates sidebar state)
extension TabStore {
    private func arcTargetSignature(_ record: ArcImportRecord) -> String? {
        switch record.kind {
        case .space:
            return spaces.first(where: { $0.id == record.targetID }).map { ArcImportReader.signature($0) }
        case .folder:
            return folder(record.targetID).map { value in
                ArcImportReader.signature(value) + ":" + String(pinnedChildren(of: value.parentID, spaceID: value.spaceID).firstIndex(of: .folder(value.id)) ?? -1)
            }
        case .bookmark:
            return bookmark(record.targetID).map { value in
                let index = value.spaceID.map { pinnedChildren(of: value.folderID, spaceID: $0).firstIndex(of: .bookmark(value.id)) ?? -1 }
                    ?? bookmarks.filter { $0.spaceID == nil && $0.arcProfileID == value.arcProfileID }.firstIndex(where: { $0.id == value.id }) ?? -1
                return ArcImportReader.signature(value) + ":" + String(index)
            }
        case .tab:
            return arcMigration.tabs.first(where: { $0.id == record.sourceID }).map { ArcImportReader.hash(Data("\($0.title)\n\($0.url)\n\($0.spaceID)\n\($0.profileID)".utf8)) }
        }
    }

    func arcDisposition(id: String, signature: String, issue: String? = nil) -> ArcImportDisposition {
        if issue != nil { return .attention }
        guard let record = arcMigration.records[id] else { return .add }
        guard record.sourceSignature == signature, arcTargetSignature(record) == record.targetSignature else { return .conflict }
        return .retained
    }
    func arcDisposition(_ entry: ArcImportEntry) -> ArcImportDisposition {
        arcDisposition(id: entry.id, signature: entry.signature, issue: entry.issue ?? (entry.kind == .folder && entry.spaceID == nil ? "Favorites folders need manual handling." : nil))
    }
    func arcDisposition(_ space: ArcImportSpace) -> ArcImportDisposition {
        arcDisposition(id: space.id, signature: ArcImportReader.signature(space))
    }
    var arcPendingTabs: [ArcTabRestore] { arcMigration.tabs.filter { $0.status == .pending || $0.status == .sending } }

    /// State and the import ledger commit in the same atomic file. Never overwrite a live
    /// state file from an external script. Failed writes restore the in-memory transaction.
    private func arcTransaction(_ change: () throws -> Void) throws {
        let oldBookmarks = bookmarks, oldSpaces = spaceState, oldFolders = folderState, oldMigration = arcMigration
        let oldNames = customNames, oldLinks = bookmarkLinks
        do {
            try change()
            try persistState()
        } catch {
            bookmarks = oldBookmarks; spaceState = oldSpaces; folderState = oldFolders; arcMigration = oldMigration
            customNames = oldNames; bookmarkLinks = oldLinks
            throw error
        }
    }

    @discardableResult
    func importArc(_ snapshot: ArcImportSnapshot, selectedSpaces: Set<String>, includeFavorites: Bool) throws -> ArcImportReceipt {
        guard !arcRestoreRunning else { throw ArcImportFailure(message: "Pause tab restoration before starting another import.") }
        guard !selectedSpaces.isEmpty else { throw ArcImportFailure(message: "Select at least one Arc space.") }
        guard Set(snapshot.spaces.map(\.id)).isSuperset(of: selectedSpaces) else { throw ArcImportFailure(message: "The space selection is invalid. Refresh the preview.") }
        let fresh = try ArcImportReader.read(snapshot.sourceURL)
        guard fresh.hash == snapshot.hash else { throw ArcImportFailure(message: "Arc changed since this preview. Refresh it before importing.") }
        let selected = snapshot.spaces.filter { selectedSpaces.contains($0.id) }
        let profiles = Set(selected.map(\.profileID))
        let eligible = snapshot.entries.filter { entry in
            entry.spaceID.map(selectedSpaces.contains) ?? (includeFavorites && profiles.contains(entry.profileID))
        }
        let entryDispositions = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, arcDisposition($0)) })
        let spaceDispositions = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, arcDisposition($0)) })
        let batch = UUID()
        let backup = persistenceURL.deletingLastPathComponent().appendingPathComponent("Arc Imports/\(batch.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encodedState().write(to: backup.appendingPathComponent("before.json"), options: .atomic)
        try snapshot.data.write(to: backup.appendingPathComponent("Arc-sidebar.json"), options: .atomic)
        for name in ["before.json", "Arc-sidebar.json"] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.appendingPathComponent(name).path) }
        var receipt = ArcImportReceipt(id: batch, snapshotHash: snapshot.hash, added: 0, retained: 0,
                                       conflicts: [], attention: [], backupPath: backup.path)
        try arcTransaction {
            var newKeys: [String] = []
            for source in selected {
                switch spaceDispositions[source.id]! {
                case .add:
                    let target = BrowserSpace(name: source.name, icon: source.icon, theme: source.theme,
                        arcProfileID: source.profileID, emoji: source.originalIcon.flatMap(BrowserSpace.normalizedEmoji))
                    spaceState.spaces.append(target)
                    arcMigration.records[source.id] = ArcImportRecord(sourceID: source.id, targetID: target.id, kind: .space,
                        sourceSignature: ArcImportReader.signature(source), targetSignature: "", batchID: batch)
                    newKeys.append(source.id); receipt.added += 1
                case .retained: receipt.retained += 1
                default: receipt.conflicts.append("Space ‘\(source.name)’ changed or was removed. Kept the Safari version.")
                }
            }
            for source in eligible {
                let disposition = entryDispositions[source.id]!
                if disposition == .attention { receipt.attention.append(source); continue }
                if disposition == .retained { receipt.retained += 1; continue }
                if disposition == .conflict {
                    receipt.conflicts.append("‘\(source.title)’ changed or was removed. Kept the Safari version."); continue
                }
                let spaceID = source.spaceID.flatMap { arcMigration.records[$0]?.targetID }
                if source.spaceID != nil && !spaces.contains(where: { $0.id == spaceID }) {
                    receipt.conflicts.append("‘\(source.title)’ was skipped because its destination space was removed."); continue
                }
                let parentID = source.parentID.flatMap { arcMigration.records[$0]?.targetID }
                if source.parentID != nil && folder(parentID ?? UUID()) == nil {
                    receipt.conflicts.append("‘\(source.title)’ was skipped because its destination folder needs review."); continue
                }
                let targetID: UUID
                let targetKind: ArcImportRecord.Kind
                switch source.kind {
                case .folder:
                    guard let spaceID else { receipt.attention.append(source); continue }
                    let target = PinnedFolder(name: source.title, spaceID: spaceID, parentID: parentID, isExpanded: false)
                    folderState.folders.append(target); folderState.order.append(.folder(target.id))
                    targetID = target.id; targetKind = .folder
                case .pin, .favorite:
                    guard let url = source.url else { receipt.attention.append(source); continue }
                    let target = Bookmark(title: source.title, url: url, spaceID: spaceID, folderID: parentID,
                                          arcProfileID: source.kind == .favorite ? source.profileID : nil)
                    bookmarks.append(target)
                    if spaceID != nil { folderState.order.append(.bookmark(target.id)) }
                    targetID = target.id; targetKind = .bookmark
                case .tab:
                    guard let url = source.url, let spaceID else { receipt.attention.append(source); continue }
                    arcMigration.tabs.append(.init(id: source.id, title: source.title, url: url,
                                                  spaceID: spaceID, profileID: source.profileID, batchID: batch))
                    targetID = UUID(); targetKind = .tab
                case .unsupported: receipt.attention.append(source); continue
                }
                arcMigration.records[source.id] = .init(sourceID: source.id, targetID: targetID, kind: targetKind,
                    sourceSignature: source.signature, targetSignature: "", batchID: batch)
                newKeys.append(source.id); receipt.added += 1
            }
            for key in newKeys {
                if let record = arcMigration.records[key] {
                    let signature = arcTargetSignature(record) ?? ""
                    arcMigration.records[key]?.targetSignature = signature
                }
            }
            arcMigration.receipts.append(receipt)
        }
        // The authoritative receipt is in state.json; the bundle copy is for inspection.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(receipt).write(to: backup.appendingPathComponent("receipt.json"), options: .atomic)
        return receipt
    }

    /// Explicitly resume only queued work, in regular Safari windows chosen by the user.
    /// Sending requests keep their original token/destination, even across an app restart.
    func restoreArcTabs(destinations: [String: ArcImportDestination]) {
        guard !arcRestoreRunning else { return }
        arcRestoreDestinations = destinations
        arcRestoreRunning = true; arcRestoreMessage = nil
        sendNextArcTab()
    }
    func markArcTabHandled(_ id: String) throws {
        guard !arcRestoreRunning, let index = arcMigration.tabs.firstIndex(where: { $0.id == id }),
              arcMigration.tabs[index].status != .restored else { return }
        try arcTransaction {
            arcMigration.tabs[index].status = .cancelled
            arcMigration.tabs[index].message = "Handled manually. This source item will not be reopened by repeat imports."
        }
    }

    func pauseArcRestore() {
        arcRestoreRunning = false
        arcRestoreTimeout?.cancel(); arcRestoreTimeout = nil
        arcRestoreMessage = "Paused. Completed tabs will stay closed if you close them. Resume to continue queued tabs."
    }
    private func sendNextArcTab() {
        guard arcRestoreRunning else { return }
        guard let index = arcMigration.tabs.firstIndex(where: { $0.status == .sending })
                ?? arcMigration.tabs.firstIndex(where: { $0.status == .pending && arcRestoreDestinations[$0.profileID] != nil }) else {
            arcRestoreRunning = false
            arcRestoreMessage = arcPendingTabs.isEmpty ? "Tab restoration finished." : "Remaining tabs are saved for later. Choose destination windows to restore them."
            return
        }
        let job = arcMigration.tabs[index]
        guard spaces.contains(where: { $0.id == job.spaceID }) else {
            arcRestoreRunning = false; arcRestoreMessage = "A queued tab's space was removed. Review the import before continuing."
            return
        }
        let destination = job.status == .sending ? job.destination : arcRestoreDestinations[job.profileID]
        guard let destination, snapshots[destination.instance]?.capabilities?.contains("arcMigrationV1") == true,
              let window = snapshots[destination.instance]?.windows.first(where: { $0.id == destination.windowID }),
              !window.incognito, sendCommand != nil else {
            arcRestoreRunning = false
            arcRestoreMessage = job.status == .sending ? "The original Safari window is unavailable. This tab's result is uncertain; it will not be opened again automatically." : "Choose a regular Safari window for ‘\(job.profileID)’ and resume."
            return
        }
        do {
            try arcTransaction {
                arcMigration.tabs[index].status = .sending
                arcMigration.tabs[index].destination = destination
            }
        } catch { arcRestoreRunning = false; arcRestoreMessage = error.localizedDescription; return }
        send(["action": "migrationCreate", "requestId": job.requestID, "url": job.url, "windowId": destination.windowID, "active": false], to: destination.instance)
        arcRestoreTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.arcRestoreRunning,
                  self.arcMigration.tabs.contains(where: { $0.requestID == job.requestID && $0.status == .sending }) else { return }
            self.arcRestoreRunning = false
            self.arcRestoreMessage = "Waiting for Safari's acknowledgement. Resume to check the same request safely."
        }
        arcRestoreTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    private func handleArcRestoreReply(type: String, object: [String: Any]) {
        guard let request = object["requestId"] as? String,
              let index = arcMigration.tabs.firstIndex(where: { $0.requestID == request && $0.status == .sending }),
              let instance = object["instance"] as? String,
              arcMigration.tabs[index].destination?.instance == instance else { return }
        do {
            try arcTransaction {
                if type == "migrationCreated", let id = object["tabId"] as? Int {
                    let key = TabKey(instance: instance, tabId: id), job = arcMigration.tabs[index]
                    let owner = spaces.contains(where: { $0.id == job.spaceID }) ? job.spaceID : selectedSpace.id
                    arcMigration.tabs[index].status = .restored; arcMigration.tabs[index].key = key
                    if spaceState.spaceID(for: key) == nil {
                        let windowIndex = snapshots[instance]?.windows.firstIndex(where: { $0.id == job.destination?.windowID }) ?? 0
                        spaceState.memberships.append(.init(key: key, spaceID: owner, url: job.url, windowIndex: windowIndex,
                            privateWindow: false, profile: snapshots[instance]?.profile))
                    } else { spaceState.assign(key, to: owner) }
                    customNames[key] = CustomName(name: job.title, url: job.url)
                } else {
                    arcMigration.tabs[index].status = .attention
                    arcMigration.tabs[index].message = object["message"] as? String ?? "Safari could not confirm this tab. Review it manually before opening a replacement."
                }
            }
            arcRestoreTimeout?.cancel(); arcRestoreTimeout = nil
            if arcRestoreRunning { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.sendNextArcTab() } }
        } catch { arcRestoreRunning = false; arcRestoreMessage = "Could not save Safari's acknowledgement: \(error.localizedDescription). Resume to check safely." }
    }

    /// Undo only owned, unchanged objects. Live Safari tabs are deliberately retained.
    /// Edited folders/spaces and containers with later user content are never removed.
    func undoArcImport(_ batchID: UUID) throws {
        pauseArcRestore()
        try arcTransaction {
            let records = arcMigration.records.values.filter { $0.batchID == batchID }
            let unchanged = Set(records.filter { arcTargetSignature($0) == $0.targetSignature }.map(\.sourceID))
            for record in records where record.kind == .bookmark && unchanged.contains(record.sourceID) {
                bookmarks.removeAll { $0.id == record.targetID }
                folderState.order.removeAll { $0 == .bookmark(record.targetID) }
                bookmarkLinks[record.targetID] = nil
                arcMigration.records[record.sourceID] = nil
            }
            var pending = records.filter { $0.kind == .folder && unchanged.contains($0.sourceID) }
            while let index = pending.firstIndex(where: { record in
                folder(record.targetID).map { pinnedChildren(of: $0.id, spaceID: $0.spaceID).isEmpty } == true
            }) {
                let record = pending.remove(at: index)
                folderState.folders.removeAll { $0.id == record.targetID }
                folderState.order.removeAll { $0 == .folder(record.targetID) }
                arcMigration.records[record.sourceID] = nil
            }
            for index in arcMigration.tabs.indices where arcMigration.tabs[index].batchID == batchID {
                if arcMigration.tabs[index].status != .restored { arcMigration.tabs[index].status = .cancelled }
            }
            for record in records where record.kind == .space && unchanged.contains(record.sourceID) {
                guard !spaceState.memberships.contains(where: { $0.spaceID == record.targetID }),
                      !bookmarks.contains(where: { $0.spaceID == record.targetID }),
                      !folders.contains(where: { $0.spaceID == record.targetID }), spaces.count > 1 else { continue }
                _ = spaceState.remove(record.targetID)
                arcMigration.records[record.sourceID] = nil
            }
            if let index = arcMigration.receipts.firstIndex(where: { $0.id == batchID }) { arcMigration.receipts[index].undone = true }
        }
    }
}
