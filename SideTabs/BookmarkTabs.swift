import Foundation

// Which open tabs belong to bookmarks (#25). Opening a bookmark gives it a tab of its own, which
// stays with it wherever the tab browses, until the tab closes. The sidebar lists that tab under
// its bookmark instead of under Tabs. The rules are kept here, apart from SwiftUI and Safari, so
// Tests/StoreChecks can check them; TabStore calls in when its tabs or bookmarks change.

/// The tabs that belong to bookmarks. Each window has its own tab for a bookmark, and a tab belongs
/// to at most one bookmark.
///
/// Tab ids last as long as the extension's background page: when Safari restarts, every tab comes
/// back with a new id, under a new extension instance. A bookmark then gets back a restored tab only
/// if that tab is still on the bookmark's saved page. One that had gone to another page comes back
/// under Tabs, because nothing else says which tab it was.
struct BookmarkTabs: Equatable {
    /// How long after Safari starts a restored tab can still go back to its bookmark. Safari restores
    /// windows over the first few seconds, not always with events (the extension sends snapshots for
    /// six seconds after it starts). A tab opened after this is a new one.
    static let restoreWindow: TimeInterval = 15

    /// How long a new link is safe from a snapshot that lacks its tab and has no start time (an
    /// extension page from before snapshots had one).
    static let unstampedGrace: TimeInterval = 2

    private struct Link: Equatable {
        let bookmark: UUID
        /// When the tab became the bookmark's. A snapshot started before then may not have the tab
        /// yet (one only just opened for the bookmark), so its absence there doesn't mean it closed.
        let since: Date
    }

    /// A bookmark whose tab went away with Safari's old tab ids. It may claim one restored tab.
    private struct Restorable: Equatable {
        let bookmark: UUID
        let since: Date
    }

    private var links: [TabKey: Link] = [:]
    private var restorable: [Restorable] = []
    /// The extension instances that started after the tabs in `restorable` went away. Only their
    /// tabs can be restored ones.
    private var restoringInstances: Set<String> = []
    /// The extension instances running now, or when the links were last saved. One that isn't among
    /// them is a background page that has just started: Safari restarted (or a profile was added),
    /// so the instances that haven't reported since are gone, and their tab ids with them.
    private var knownInstances: Set<String> = []

    init() {}

    // MARK: Reading

    /// Each tab that belongs to a bookmark, and that bookmark's id.
    var owners: [TabKey: UUID] { links.mapValues(\.bookmark) }

    func bookmark(owning key: TabKey) -> UUID? {
        links[key]?.bookmark
    }

    /// The bookmark's tab in `window`, if it has one there.
    func tab(of bookmark: UUID, in window: BrowserWindow, instance: String) -> BrowserTab? {
        window.tabs.first { links[TabKey(instance: instance, tabId: $0.id)]?.bookmark == bookmark }
    }

    // MARK: Changes

    /// Makes the tab the bookmark's. A tab that already belongs to a bookmark stays with it. The
    /// caller checks that the bookmark has no other tab in the window.
    mutating func link(_ key: TabKey, to bookmark: UUID, at now: Date = Date()) {
        guard links[key] == nil else { return }
        links[key] = Link(bookmark: bookmark, since: now)
    }

    /// The tabs no longer belong to their bookmarks: they closed, or are closing.
    mutating func unlink(_ keys: some Sequence<TabKey>) {
        for key in keys {
            links[key] = nil
        }
    }

    /// The bookmark was removed. Its tabs go back under Tabs, and none is restored for it.
    mutating func forget(bookmark: UUID) {
        links = links.filter { $0.value.bookmark != bookmark }
        restorable.removeAll { $0.bookmark == bookmark }
    }

    /// Lets go of the tabs in `snapshot` whose bookmark the tab's window doesn't show (#34, #38): `shown`
    /// gives the ids of the bookmarks a window shows, which are its profile's Favorites and Pinned list,
    /// and none in a private window. So links never cross profiles: a tab of another profile's window, or
    /// of a private one (as a state.json from when favorites were shared can have), goes back under Tabs,
    /// rather than belonging to a bookmark nothing in that window stands for.
    mutating func unlinkTabs(in snapshot: Snapshot, notShown shown: (BrowserWindow) -> Set<UUID>) {
        for window in snapshot.windows {
            let ids = shown(window)
            for tab in window.tabs {
                let key = TabKey(instance: snapshot.instance, tabId: tab.id)
                if let link = links[key], !ids.contains(link.bookmark) {
                    links[key] = nil
                }
            }
        }
    }

    /// Brings the links up to date with a snapshot from one extension instance. `live` is every
    /// instance with a snapshot, this one included. `bookmarks` is every bookmark in every list, and
    /// `shown` the ids of those a window of the snapshot shows (see `unlinkTabs`): a tab only belongs
    /// to a bookmark its window shows.
    mutating func update(
        with snapshot: Snapshot,
        live: Set<String>,
        bookmarks: [Bookmark],
        shown: (BrowserWindow) -> Set<UUID>,
        now: Date = Date()
    ) {
        let instance = snapshot.instance
        if !knownInstances.contains(instance) {
            // A background page that has just started. The instances that haven't reported are gone
            // (Safari quit or restarted), and so are their tab ids: each of their bookmarks' tabs may
            // come back as a restored tab instead.
            for (key, link) in links where !live.contains(key.instance) {
                links[key] = nil
                restorable.append(Restorable(bookmark: link.bookmark, since: now))
            }
            knownInstances = live
            restoringInstances.insert(instance)
        }

        // Tabs that closed. A snapshot started before a link was made can lack a tab that had only
        // just opened, so it only counts for links older than itself.
        let startedAt = snapshot.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        let tabIds = Set(snapshot.windows.flatMap(\.tabs).map(\.id))
        for (key, link) in links where key.instance == instance && !tabIds.contains(key.tabId) {
            let olderThanLink = startedAt.map { $0 < link.since } ?? (now.timeIntervalSince(link.since) < Self.unstampedGrace)
            if !olderThanLink {
                links[key] = nil
            }
        }

        unlinkTabs(in: snapshot, notShown: shown)

        // One tab per bookmark in each window. A bookmark's tab moved into a window where the
        // bookmark already has one: the one showing stays the bookmark's (or the first), and the
        // other goes back under Tabs.
        for window in snapshot.windows {
            let owned = window.tabs.filter { links[TabKey(instance: instance, tabId: $0.id)] != nil }
            let byBookmark = Dictionary(grouping: owned) { links[TabKey(instance: instance, tabId: $0.id)]?.bookmark }
            for tabs in byBookmark.values where tabs.count > 1 {
                let kept = tabs.first(where: \.active) ?? tabs[0]
                for tab in tabs where tab.id != kept.id {
                    links[TabKey(instance: instance, tabId: tab.id)] = nil
                }
            }
        }

        // Restored tabs: tabs of a background page that started since, still on a saved page whose
        // bookmark has no tab in their window yet, and that their window shows (a pinned item only
        // gets back a tab of its own profile).
        let bookmarkIds = Set(bookmarks.map(\.id))
        restorable.removeAll { now.timeIntervalSince($0.since) >= Self.restoreWindow || !bookmarkIds.contains($0.bookmark) }
        if restorable.isEmpty {
            restoringInstances.removeAll()
        }
        guard restoringInstances.contains(instance) else { return }
        let savedPages = Dictionary(bookmarks.map { ($0.id, $0.url.comparableURL) }, uniquingKeysWith: { first, _ in first })
        for window in snapshot.windows {
            let ids = shown(window)
            for tab in window.tabs {
                let key = TabKey(instance: instance, tabId: tab.id)
                guard links[key] == nil, let page = tab.url?.comparableURL,
                      let index = restorable.firstIndex(where: {
                          ids.contains($0.bookmark) && savedPages[$0.bookmark] == page
                              && self.tab(of: $0.bookmark, in: window, instance: instance) == nil
                      }) else { continue }
                links[key] = Link(bookmark: restorable[index].bookmark, since: now)
                restorable.remove(at: index)
            }
        }
    }

    /// Safari quit, and its tab ids with it. The links are kept (and saved) until it starts again:
    /// the first background page to start then turns them into tabs to restore (see `update`).
    mutating func safariDidTerminate() {
        knownInstances.removeAll()
        restoringInstances.removeAll()
    }

    // MARK: Saving

    /// A link as state.json keeps it.
    struct Saved: Codable, Equatable {
        let instance: String
        let tabId: Int
        let bookmark: UUID
    }

    /// The links saved with the bookmarks, and the extension instances running when they were saved.
    /// Links to bookmarks that are gone are dropped.
    init(saved: [Saved], instances: [String], bookmarks: [Bookmark]) {
        let bookmarkIds = Set(bookmarks.map(\.id))
        for link in saved where bookmarkIds.contains(link.bookmark) {
            links[TabKey(instance: link.instance, tabId: link.tabId)] = Link(bookmark: link.bookmark, since: .distantPast)
        }
        knownInstances = Set(instances)
    }

    var saved: [Saved] {
        links
            .map { Saved(instance: $0.key.instance, tabId: $0.key.tabId, bookmark: $0.value.bookmark) }
            .sorted { ($0.instance, $0.tabId) < ($1.instance, $1.tabId) }
    }

    var savedInstances: [String] { knownInstances.sorted() }
}

extension TabStore {
    /// The tabs listed under Tabs in `window`: all of them except the tabs of the favorites and
    /// pinned items the window shows, which their tiles and rows stand for. With those hidden
    /// (Settings), every tab is listed.
    func tabsListed(in window: BrowserWindow, instance: String, bookmarksShown: Bool = true) -> [BrowserTab] {
        guard bookmarksShown else { return window.tabs }
        // Only bookmarks this window shows: a tab can't be left out for one nothing here stands for.
        // (The links are kept that way, see `BookmarkTabs.unlinkTabs`; this makes sure of it.)
        let shown = bookmarkIds(shownIn: window, instance: instance)
        return window.tabs.filter { tab in
            bookmarkTabs.bookmark(owning: TabKey(instance: instance, tabId: tab.id)).map { !shown.contains($0) } ?? true
        }
    }

    /// Closes the bookmark's tab in the window the sidebar shows, which puts the bookmark back to
    /// closed: the next click opens its saved page. It's what a pinned row's "−", a middle click on
    /// a row or tile, and a tile's Close Tab do. Says whether there was a tab to close.
    @discardableResult
    func closeBookmarkTab(_ id: UUID) -> Bool {
        guard let selection = currentWindow,
              let bookmark = bookmarkLists.bookmark(id),
              let tab = openTab(for: bookmark) else { return false }
        close([tab], instance: selection.instance)
        return true
    }

    /// Moves a tab to `slot` in the Tabs list, which leaves out bookmarks' tabs: just before the
    /// tab listed there now, or just after the last one listed, wherever that is among the window's
    /// tabs.
    func moveTab(_ tab: BrowserTab, instance: String, toListedSlot slot: Int, bookmarksShown: Bool = true) {
        guard let window = snapshots[instance]?.windows.first(where: { $0.id == tab.windowId }) else { return }
        let others = window.tabs.filter { $0.id != tab.id }
        let listed = tabsListed(in: window, instance: instance, bookmarksShown: bookmarksShown).filter { $0.id != tab.id }
        let index: Int
        if listed.indices.contains(slot), let position = others.firstIndex(where: { $0.id == listed[slot].id }) {
            index = position
        } else if let last = listed.last, let position = others.firstIndex(where: { $0.id == last.id }) {
            index = position + 1
        } else {
            return
        }
        moveTab(tab, instance: instance, to: index)
    }
}
