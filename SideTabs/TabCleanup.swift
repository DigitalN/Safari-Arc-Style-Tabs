import Foundation
import Observation
import os.log

// Tab cleanup (#27): a setting, off by default, that closes tabs nobody has looked at for a while,
// like Arc's archive, and keeps them in a list at the bottom left of the sidebar for reopening.
//
// The rules are plain functions (the static ones on TabCleanup), so Tests/TabCleanupChecks can check
// them without Safari. TabStore keeps one TabCleanup, which holds each tab's clock and the list of
// closed tabs and saves both in state.json. The TabStore extension at the bottom closes and reopens
// tabs. When cleanup runs is up to TabCleanupScheduler.

/// How long a tab can go without being looked at before cleanup closes it.
enum CleanupInterval: String, CaseIterable, Identifiable {
    case twelveHours, oneDay, oneWeek, thirtyDays

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .twelveHours: 12 * 60 * 60
        case .oneDay: 24 * 60 * 60
        case .oneWeek: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        }
    }

    var label: String {
        switch self {
        case .twelveHours: "12 hours"
        case .oneDay: "1 day"
        case .oneWeek: "1 week"
        case .thirtyDays: "30 days"
        }
    }
}

/// A tab cleanup closed, kept so it can be reopened. Its title and URL are browsing history: they're
/// kept in state.json and shown in the sidebar, and never written to the log.
struct ClosedTab: Codable, Identifiable, Hashable {
    var id = UUID()
    /// The page's title when the tab was closed.
    var title: String
    /// The name the user gave the tab, if any.
    var customName: String?
    var url: String
    var faviconURL: String?
    var closedAt: Date
    /// The Safari profile the tab was in, as Safari identifies it to the extension (see
    /// SafariWebExtensionHandler), so it can reopen there. Nil when Safari didn't say.
    var profile: String?

    var shownTitle: String { customName ?? title }
}

/// Each tab's clock, and the tabs cleanup closed.
@Observable
final class TabCleanup {
    /// The list keeps at most this many tabs...
    static let listLimit = 100
    /// ... and none closed longer ago than this.
    static let listLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// How long after the clocks start (Side Tabs launching, or the setting turned on) every extension
    /// instance that is still alive has surely reported. The background page sends a heartbeat every
    /// 5 seconds and is asked for a snapshot on the first one, but under load it has run 20 s late.
    /// After this, clocks of instances that haven't reported belong to a Safari that has quit.
    static let instanceGracePeriod: TimeInterval = 2 * 60
    /// How long Side Tabs can be away (quit, or restarting into an update) before the clocks it saved
    /// no longer hold. Nobody sees which tabs are looked at while it isn't running.
    static let restartAllowance: TimeInterval = 5 * 60

    /// Tabs cleanup closed, newest first.
    private(set) var closedTabs: [ClosedTab] = []

    /// When each tab was last looked at: the moment it stopped being in use (see `isInUse`), or when
    /// it was first seen. By extension instance and tab id, because tab ids are only unique within
    /// one instance and change when Safari restarts. Only kept while cleanup is on, and never for a
    /// private window's tabs.
    @ObservationIgnored private(set) var lastViewed: [TabKey: Date] = [:]

    /// Whether the clocks run: the setting, passed on by TabCleanupScheduler.
    @ObservationIgnored private(set) var isOn = false
    @ObservationIgnored private var runningSince = Date.distantFuture
    /// When a run last had the clocks saved. Runs come every few minutes, and also whenever Safari
    /// comes forward, which can be often; the clocks don't need saving that often.
    @ObservationIgnored private var clocksSavedAt = Date.distantPast

    /// Reads the time. Only the checks in Tests/ pass anything else.
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// Called when something worth saving has changed. TabStore saves state.json.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "cleanup")

    /// Starts or stops the clocks. Turned on, every tab's clock starts now, so nothing closes until the
    /// chosen time has passed; clocks saved by an earlier launch of Side Tabs are kept. Turned off, the
    /// clocks are dropped (they'd be wrong by the time it's turned on again). The list is kept either way.
    func setOn(_ on: Bool, tabs snapshots: [String: Snapshot]) {
        if on {
            guard !isOn else { return }
            isOn = true
            runningSince = clock()
            Self.noteViewing(&lastViewed, from: [:], to: snapshots, now: runningSince)
            onChange?()
        } else {
            isOn = false
            runningSince = .distantFuture
            guard !lastViewed.isEmpty else { return }
            lastViewed = [:]
            onChange?()
        }
    }

    /// TabStore calls this whenever its picture of Safari changes: a snapshot, a report of a tab switch,
    /// a click, a tab closed. Not saved from here, because it happens many times a second; each run
    /// saves the clocks (see `refresh`), and so does quitting.
    func snapshotsChanged(from old: [String: Snapshot], to new: [String: Snapshot]) {
        guard isOn else { return }
        Self.noteViewing(&lastViewed, from: old, to: new, now: clock())
    }

    /// What every run does before choosing tabs to close: tabs in use are looked at as of now, so the
    /// saved clocks stay current while nothing in Safari changes; the clocks of instances that are gone
    /// are dropped; and old entries leave the list.
    func refresh(_ snapshots: [String: Snapshot]) {
        guard isOn else { return }
        let now = clock()
        Self.noteViewing(&lastViewed, from: snapshots, to: snapshots, now: now)
        if now.timeIntervalSince(runningSince) >= Self.instanceGracePeriod {
            let live = Set(snapshots.keys)
            lastViewed = lastViewed.filter { live.contains($0.key.instance) }
        }
        let pruned = Self.pruned(closedTabs, now: now)
        let listChanged = pruned != closedTabs
        if listChanged {
            closedTabs = pruned
        }
        if listChanged || now.timeIntervalSince(clocksSavedAt) >= 60 {
            clocksSavedAt = now
            onChange?()
        }
    }

    func record(_ closed: [ClosedTab]) {
        guard !closed.isEmpty else { return }
        closedTabs = Self.list(closedTabs, adding: closed, now: clock())
        onChange?()
    }

    func remove(_ id: UUID) {
        guard closedTabs.contains(where: { $0.id == id }) else { return }
        closedTabs.removeAll { $0.id == id }
        onChange?()
    }

    // MARK: - Saving

    struct Saved: Codable {
        struct Time: Codable {
            let instance: String
            let tabId: Int
            let at: Date
        }

        var lastViewed: [Time]
        var closedTabs: [ClosedTab]
        /// When the clocks were saved, to tell a quick restart from a longer time away. Nil in a file
        /// saved before it was kept.
        var savedAt: Date?
    }

    var saved: Saved {
        let times = lastViewed
            .map { Saved.Time(instance: $0.key.instance, tabId: $0.key.tabId, at: $0.value) }
            .sorted { ($0.instance, $0.tabId) < ($1.instance, $1.tabId) }
        return Saved(lastViewed: times, closedTabs: closedTabs, savedAt: clock())
    }

    /// Takes back what was saved. The clocks only come back after a quick restart (see
    /// `clocksStillHold`); otherwise every tab's clock starts over, as when cleanup is turned on.
    func restore(_ saved: Saved?) {
        guard let saved else { return }
        let now = clock()
        if Self.clocksStillHold(savedAt: saved.savedAt, now: now) {
            lastViewed = Dictionary(
                saved.lastViewed.map { (TabKey(instance: $0.instance, tabId: $0.tabId), $0.at) },
                uniquingKeysWith: { max($0, $1) }
            )
        } else if !saved.lastViewed.isEmpty {
            log.notice("Side Tabs was away for more than \(Int(Self.restartAllowance / 60)) min; every tab's clock starts over")
        }
        closedTabs = Self.pruned(saved.closedTabs, now: now)
    }

    // MARK: - Rules

    /// Whether clocks saved at `savedAt` still hold when Side Tabs starts again at `now`. Only after a
    /// quick restart, such as an update: while Side Tabs isn't running, tabs can be looked at without it
    /// seeing, and a clock that kept running then could close a tab that was looked at a minute ago.
    static func clocksStillHold(savedAt: Date?, now: Date) -> Bool {
        guard let savedAt else { return false }
        return now.timeIntervalSince(savedAt) <= restartAllowance
    }

    /// Whether a tab is being looked at right now: it's the active tab in its window. A tab playing
    /// sound counts too, so pausing a video or a podcast that played for hours doesn't close its tab a
    /// few minutes later. (Cleanup never closes a tab while it plays sound either.)
    static func isInUse(_ tab: BrowserTab) -> Bool {
        tab.active || tab.audible
    }

    /// Only a tab with a web page can be reopened from the list. Any other (a blank tab, the start
    /// page, a tab whose URL Safari hides until the extension is allowed on websites) is left open.
    static func canReopen(_ url: String?) -> Bool {
        guard let url, let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Updates the clocks for a change from `old` to `new`. A tab in use in either was looked at until
    /// `now`; a tab seen for the first time starts its clock now; a tab that's gone from its instance,
    /// or an instance that's gone (Safari quit), loses its clock. Instances in neither keep theirs:
    /// those were saved by an earlier launch of Side Tabs and may still report. Private windows' tabs
    /// get no clock, so nothing about private browsing is kept.
    static func noteViewing(_ times: inout [TabKey: Date], from old: [String: Snapshot], to new: [String: Snapshot], now: Date) {
        for (instance, snapshot) in old {
            for window in snapshot.windows where !window.incognito {
                for tab in window.tabs where isInUse(tab) {
                    times[TabKey(instance: instance, tabId: tab.id)] = now
                }
            }
        }
        var present: [String: Set<Int>] = [:]
        for (instance, snapshot) in new {
            var ids = Set<Int>()
            for window in snapshot.windows where !window.incognito {
                for tab in window.tabs {
                    ids.insert(tab.id)
                    let key = TabKey(instance: instance, tabId: tab.id)
                    if isInUse(tab) || times[key] == nil {
                        times[key] = now
                    }
                }
            }
            present[instance] = ids
        }
        let gone = Set(old.keys).subtracting(new.keys)
        times = times.filter { key, _ in
            if let ids = present[key.instance] {
                return ids.contains(key.tabId)
            }
            return !gone.contains(key.instance)
        }
    }

    /// The tabs to close: those nobody has looked at for `interval`. Never a tab in use (the active tab
    /// in its window, or one playing sound), a pinned tab, a bookmark's tab, a tab in a private window,
    /// or one that couldn't be reopened from the list. A tab without a clock has only just been seen.
    static func tabsToClose(
        in snapshots: [String: Snapshot],
        lastViewed: [TabKey: Date],
        now: Date,
        after interval: TimeInterval,
        bookmarkTabs: Set<TabKey>
    ) -> [TabKey] {
        var keys: [TabKey] = []
        for instance in snapshots.keys.sorted() {
            for window in snapshots[instance]?.windows ?? [] where !window.incognito {
                for tab in window.tabs {
                    let key = TabKey(instance: instance, tabId: tab.id)
                    guard !isInUse(tab), !tab.pinned, !bookmarkTabs.contains(key), canReopen(tab.url),
                          let viewed = lastViewed[key], now.timeIntervalSince(viewed) >= interval else { continue }
                    keys.append(key)
                }
            }
        }
        return keys
    }

    /// The list with `closed` added at the top.
    static func list(_ list: [ClosedTab], adding closed: [ClosedTab], now: Date) -> [ClosedTab] {
        pruned(closed + list, now: now)
    }

    /// The list newest first, with one entry per page (the newest), none closed longer ago than
    /// `listLifetime`, and at most `listLimit` entries.
    static func pruned(_ list: [ClosedTab], now: Date) -> [ClosedTab] {
        var seen = Set<String>()
        let newestFirst = list.enumerated()
            .sorted { $0.element.closedAt != $1.element.closedAt ? $0.element.closedAt > $1.element.closedAt : $0.offset < $1.offset }
            .map(\.element)
        let kept = newestFirst.filter { tab in
            now.timeIntervalSince(tab.closedAt) < listLifetime && seen.insert(tab.url.comparableURL).inserted
        }
        return Array(kept.prefix(listLimit))
    }

    /// A window of one extension instance.
    struct Window: Equatable {
        let instance: String
        let windowId: Int
    }

    /// Where a closed tab reopens: in a window of the profile it came from, if one is open (the current
    /// window when it's one of them, otherwise that profile's most recently focused window), or else in
    /// the current window. A private window isn't any profile's. Nil when Safari has no windows.
    static func reopenWindow(forProfile profile: String?, in snapshots: [String: Snapshot], current: Window?) -> Window? {
        if let current, let snapshot = snapshots[current.instance], snapshot.profile == profile,
           snapshot.windows.contains(where: { $0.id == current.windowId && !$0.incognito }) {
            return current
        }
        let sameProfile = snapshots.values
            .filter { $0.profile == profile }
            .sorted { $0.focusChangedAt > $1.focusChangedAt }
        for snapshot in sameProfile {
            let windows = snapshot.windows.filter { !$0.incognito }
            let recent = [snapshot.focusedWindowId, snapshot.lastFocusedWindowId].compactMap { id in
                windows.first { $0.id == id }
            }
            if let window = recent.first ?? windows.first {
                return Window(instance: snapshot.instance, windowId: window.id)
            }
        }
        return current
    }

    /// How long ago a tab was closed, short enough for the end of a row: "now", "5m", "3h", "2d".
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<(60 * 60): return "\(Int(seconds / 60))m"
        case ..<(24 * 60 * 60): return "\(Int(seconds / (60 * 60)))h"
        default: return "\(Int(seconds / (24 * 60 * 60)))d"
        }
    }
}

extension TabStore {
    /// The tabs that belong to favorites and pinned items, which cleanup leaves open: each owns one
    /// tab in each window it's open in, through `bookmarkTabs` (#25, #34).
    var bookmarkTabKeys: Set<TabKey> {
        Set(bookmarkTabs.owners.keys)
    }

    /// Closes the tabs nobody has looked at for `interval`, and puts them at the top of the list.
    func runCleanup(after interval: TimeInterval) {
        guard cleanup.isOn else { return }
        cleanup.refresh(snapshots)
        // Not while a tab is being renamed: its row would go away under the text field. The next run
        // gets to it.
        guard renaming == nil else { return }
        let keys = TabCleanup.tabsToClose(
            in: snapshots,
            lastViewed: cleanup.lastViewed,
            now: cleanup.clock(),
            after: interval,
            bookmarkTabs: bookmarkTabKeys
        )
        guard !keys.isEmpty else { return }

        let closedAt = cleanup.clock()
        var closed: [ClosedTab] = []
        var windows: [(instance: String, windowId: Int, tabs: [BrowserTab])] = []
        for key in keys {
            guard let tab = tab(for: key), let url = tab.url else { continue }
            closed.append(ClosedTab(
                title: pageTitle(for: tab),
                customName: customNames[key]?.name,
                url: url,
                faviconURL: tab.favIconUrl,
                closedAt: closedAt,
                profile: snapshots[key.instance]?.profile
            ))
            if let index = windows.firstIndex(where: { $0.instance == key.instance && $0.windowId == tab.windowId }) {
                windows[index].tabs.append(tab)
            } else {
                windows.append((key.instance, tab.windowId, [tab]))
            }
        }
        for window in windows {
            close(window.tabs, instance: window.instance)
        }
        cleanup.record(closed)
        cleanup.log.notice("closed \(closed.count) tabs not looked at for \(Int(interval / 3600)) h; \(self.cleanup.closedTabs.count) in the list")
    }

    /// Opens a closed tab's page in a new tab, in a window of the profile it came from if one is open,
    /// otherwise in the current window, and takes it off the list. A window other than the current one
    /// is brought forward, so the tab doesn't open out of sight.
    func reopen(_ closed: ClosedTab) {
        cleanup.remove(closed.id)
        let current = currentWindow.map { TabCleanup.Window(instance: $0.instance, windowId: $0.window.id) }
        guard let target = TabCleanup.reopenWindow(forProfile: closed.profile, in: snapshots, current: current) else {
            // Safari has no windows: open the page in Safari.
            newTab(url: closed.url)
            return
        }
        var command: [String: Any] = ["action": "create", "instance": target.instance, "windowId": target.windowId, "url": closed.url]
        if target != current {
            command["focus"] = true
        }
        sendCommand?(command)
        cleanup.log.notice("reopened a closed tab in \(target == current ? "the current window" : "a window of its profile", privacy: .public)")
    }
}
