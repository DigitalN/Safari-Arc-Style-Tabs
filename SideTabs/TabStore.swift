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

    private(set) var snapshots: [String: Snapshot] = [:]
    private(set) var lastMessageAt: Date?
    private(set) var bookmarks: [Bookmark] = []
    private(set) var customNames: [TabKey: CustomName] = [:]
    private(set) var bookmarkLinks: [UUID: TabKey] = [:]

    var renaming: RenameTarget?
    @ObservationIgnored var dragging: DragItem?

    /// Hints from SafariTracker, used to pick the window the sidebar is docked to.
    var safariIsFrontmost = false
    var dockedWindowTitle: String? {
        didSet {
            if dockedWindowTitle != oldValue {
                requestSnapshotIfUnknown(title: dockedWindowTitle)
            }
        }
    }
    @ObservationIgnored private var lastSnapshotRequest = Date.distantPast

    @ObservationIgnored var sendCommand: (([String: Any]) -> Void)?
    @ObservationIgnored var onToggleSidebar: (() -> Void)?
    @ObservationIgnored var onRenameStateChanged: ((Bool) -> Void)?

    /// Names whose tab ids are gone (Safari restarted), keyed by URL so they can be
    /// given back to the restored tabs.
    @ObservationIgnored private var orphanNames: [String: String] = [:]
    @ObservationIgnored private var pendingBookmarkOpens: [String: (bookmark: UUID, at: Date)] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var dragTimer: Timer?
    /// When the last tab switch was requested, to log how long Safari took to confirm it.
    @ObservationIgnored private var pendingActivation: (key: TabKey, at: Date)?
    @ObservationIgnored private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "store")

    init() {
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
            return ["needSnapshot": applied < seq || seq == 0]

        case "toggleSidebar":
            onToggleSidebar?()
            return [:]

        case "created":
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
        let isNewInstance = snapshots[snapshot.instance] == nil
        snapshots[snapshot.instance] = snapshot
        let tabCounts = snapshot.windows.map { String($0.tabs.count) }.joined(separator: "+")
        log.info("snapshot \(snapshot.seq) from \(snapshot.instance.prefix(8), privacy: .public): \(snapshot.windows.count) windows, tabs \(tabCounts, privacy: .public), focused \(snapshot.focusedWindowId ?? -1)")
        if isNewInstance {
            orphanNamesOfDeadInstances()
        }
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

    // MARK: - Tab commands

    func tab(for key: TabKey) -> BrowserTab? {
        snapshots[key.instance]?.windows.lazy.flatMap(\.tabs).first { $0.id == key.tabId }
    }

    func activate(_ tab: BrowserTab, instance: String) {
        pendingActivation = (TabKey(instance: instance, tabId: tab.id), Date())
        mutateWindow(instance: instance, windowId: tab.windowId) { window in
            for index in window.tabs.indices {
                window.tabs[index].active = window.tabs[index].id == tab.id
            }
        }
        send(["action": "activate", "tabId": tab.id], to: instance)
    }

    func close(_ tabs: [BrowserTab], instance: String) {
        guard let windowId = tabs.first?.windowId else { return }
        let ids = Set(tabs.map(\.id))
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
    }

    func closeOtherTabs(than tab: BrowserTab, instance: String) {
        guard let window = window(instance: instance, id: tab.windowId) else { return }
        close(window.tabs.filter { $0.id != tab.id && !$0.pinned }, instance: instance)
    }

    func closeTabsBelow(_ tab: BrowserTab, instance: String) {
        guard let window = window(instance: instance, id: tab.windowId),
              let index = window.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        close(Array(window.tabs[(index + 1)...]), instance: instance)
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
        send(command, to: selection.instance)
    }

    func duplicate(_ tab: BrowserTab, instance: String) {
        send(["action": "duplicate", "tabId": tab.id], to: instance)
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

    /// Live reorder while dragging; the move is sent to Safari on drop.
    func previewMove(tab dragged: TabKey, over target: BrowserTab) {
        guard dragged.tabId != target.id, let window = window(instance: dragged.instance, id: target.windowId) else { return }
        guard window.tabs.contains(where: { $0.id == dragged.tabId }) else { return }
        mutateWindow(instance: dragged.instance, windowId: target.windowId) { window in
            guard let from = window.tabs.firstIndex(where: { $0.id == dragged.tabId }),
                  let to = window.tabs.firstIndex(where: { $0.id == target.id }) else { return }
            let tab = window.tabs.remove(at: from)
            window.tabs.insert(tab, at: to)
            for index in window.tabs.indices {
                window.tabs[index].index = index
            }
        }
    }

    func commitMove(tab key: TabKey) {
        guard let tab = tab(for: key) else { return }
        send(["action": "move", "tabId": key.tabId, "index": tab.index], to: key.instance)
    }

    // MARK: - Dragging

    /// SwiftUI doesn't report drags that end outside a drop target, so watch for the
    /// mouse button going up and commit whatever order is showing.
    func beginDrag(_ item: DragItem) {
        dragging = item
        dragTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self?.finishDrag()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    func finishDrag() {
        dragTimer?.invalidate()
        dragTimer = nil
        guard let item = dragging else { return }
        dragging = nil
        switch item {
        case .tab(let key):
            commitMove(tab: key)
        case .bookmark:
            commitBookmarkOrder()
        }
    }

    /// The drag turned into something else (a tab dropped on the bookmarks), so undo any
    /// reordering it previewed.
    func cancelDrag() {
        dragTimer?.invalidate()
        dragTimer = nil
        if case .tab? = dragging {
            requestSnapshot()
        }
        dragging = nil
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

    /// The open tab in the current window that belongs to this bookmark, if any.
    func openTab(for bookmark: Bookmark) -> BrowserTab? {
        guard let selection = currentWindow else { return nil }
        if let key = bookmarkLinks[bookmark.id], key.instance == selection.instance,
           let tab = selection.window.tabs.first(where: { $0.id == key.tabId }) {
            return tab
        }
        let target = bookmark.url.comparableURL
        return selection.window.tabs.first { $0.url?.comparableURL == target }
    }

    func open(_ bookmark: Bookmark, inNewTab: Bool = false) {
        guard let selection = currentWindow else {
            openInSafari(bookmark.url)
            return
        }
        if !inNewTab, let tab = openTab(for: bookmark) {
            bookmarkLinks[bookmark.id] = TabKey(instance: selection.instance, tabId: tab.id)
            activate(tab, instance: selection.instance)
            return
        }
        // A quick second click arrives before Safari reports the new tab; don't open two.
        pendingBookmarkOpens = pendingBookmarkOpens.filter { Date().timeIntervalSince($0.value.at) < 2 }
        if !inNewTab, pendingBookmarkOpens.values.contains(where: { $0.bookmark == bookmark.id }) {
            return
        }
        let requestId = UUID().uuidString
        pendingBookmarkOpens[requestId] = (bookmark.id, Date())
        send([
            "action": "create",
            "windowId": selection.window.id,
            "url": bookmark.url,
            "requestId": requestId,
        ], to: selection.instance)
    }

    func addBookmark(from tab: BrowserTab, instance: String, at index: Int? = nil) {
        guard let url = tab.url, !url.isEmpty else { return }
        let bookmark = Bookmark(
            title: displayTitle(for: tab, instance: instance),
            url: url,
            faviconURL: tab.favIconUrl
        )
        insert(bookmark, at: index)
        bookmarkLinks[bookmark.id] = TabKey(instance: instance, tabId: tab.id)
    }

    func addBookmarkForCurrentTab() {
        guard let selection = currentWindow, let tab = selection.window.tabs.first(where: \.active) else { return }
        addBookmark(from: tab, instance: selection.instance)
    }

    func addBookmark(url: URL, at index: Int? = nil) {
        guard let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else { return }
        insert(Bookmark(title: url.host() ?? url.absoluteString, url: url.absoluteString), at: index)
    }

    private func insert(_ bookmark: Bookmark, at index: Int?) {
        let position = index.map { min(max($0, 0), bookmarks.count) } ?? bookmarks.count
        bookmarks.insert(bookmark, at: position)
        scheduleSave()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        bookmarkLinks[bookmark.id] = nil
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

    func previewMove(bookmark dragged: UUID, over target: Bookmark) {
        guard dragged != target.id,
              let from = bookmarks.firstIndex(where: { $0.id == dragged }),
              let to = bookmarks.firstIndex(where: { $0.id == target.id }) else { return }
        let bookmark = bookmarks.remove(at: from)
        bookmarks.insert(bookmark, at: to)
    }

    func commitBookmarkOrder() {
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
    }

    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Side Tabs", directoryHint: .isDirectory).appending(path: "state.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        bookmarks = state.bookmarks
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

    func save() {
        let state = SavedState(
            bookmarks: bookmarks,
            names: customNames.map { SavedName(instance: $0.key.instance, tabId: $0.key.tabId, name: $0.value) },
            orphanNames: orphanNames
        )
        do {
            let url = Self.stateURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("Side Tabs: could not save state: \(error)")
        }
    }
}
