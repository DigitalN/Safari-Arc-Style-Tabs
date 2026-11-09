import Foundation

// Checks for tab cleanup (#27): which tabs it closes, the clocks it keeps, its list of closed tabs,
// and reopening them. Run with scripts/run-checks.sh, which compiles this together with the real
// TabCleanup.swift, TabStore.swift and Models.swift. No Safari involved, and the stores here keep
// their state in a temporary folder, never the Mac's real state.json.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

let minute: TimeInterval = 60
let hour: TimeInterval = 60 * minute
let day: TimeInterval = 24 * hour
let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

func key(_ tabId: Int, _ instance: String = "A") -> TabKey {
    TabKey(instance: instance, tabId: tabId)
}

// MARK: - Building Safari's state directly, for the plain functions

func browserTab(_ id: Int, window: Int = 1, active: Bool = false, audible: Bool = false, pinned: Bool = false,
                url: String? = nil, noURL: Bool = false) -> BrowserTab {
    BrowserTab(id: id, windowId: window, index: id, title: "Tab \(id)", url: noURL ? nil : url ?? "https://example.com/\(id)",
               active: active, pinned: pinned, audible: audible, muted: false, loading: false, favIconUrl: nil)
}

func browserWindow(_ id: Int, incognito: Bool = false, _ tabs: [BrowserTab]) -> BrowserWindow {
    BrowserWindow(id: id, focused: false, incognito: incognito, tabs: tabs)
}

func snapshot(instance: String = "A", profile: String? = nil, focused: Int? = nil, lastFocused: Int? = nil,
              focusChangedAt: Double = 1, _ windows: [BrowserWindow]) -> Snapshot {
    Snapshot(instance: instance, seq: 1, focusedWindowId: focused, lastFocusedWindowId: lastFocused,
             focusChangedAt: focusChangedAt, startedAt: nil, windows: windows, profile: profile)
}

func closedTab(_ n: Int, closedAt: Date, url: String? = nil) -> ClosedTab {
    ClosedTab(title: "Page \(n)", url: url ?? "https://example.com/page-\(n)", closedAt: closedAt)
}

// MARK: - Driving a real TabStore with messages, as the extension does

var now = start
let stateFolder = FileManager.default.temporaryDirectory.appending(path: "side-tabs-cleanup-checks-\(UUID().uuidString)")
var storeCount = 0

func tabObject(_ id: Int, window: Int = 1, active: Bool = false, audible: Bool = false) -> [String: Any] {
    ["id": id, "windowId": window, "index": id, "title": "Tab \(id)", "url": "https://example.com/\(id)",
     "active": active, "pinned": false, "audible": audible, "muted": false, "loading": false,
     "favIconUrl": "https://example.com/icon-\(id).png"]
}

func windowObject(_ id: Int, incognito: Bool = false, _ tabs: [[String: Any]]) -> [String: Any] {
    ["id": id, "focused": false, "incognito": incognito, "tabs": tabs]
}

func snapshotObject(_ instance: String = "A", seq: Int, profile: String? = nil, focused: Int = 1, focusChangedAt: Double = 1,
                    _ windows: [[String: Any]]) -> [String: Any] {
    var object: [String: Any] = ["type": "snapshot", "instance": instance, "seq": seq, "focusedWindowId": focused,
                                 "lastFocusedWindowId": focused, "focusChangedAt": focusChangedAt, "windows": windows]
    if let profile { object["profile"] = profile }
    return object
}

/// One window with tabs 1...count, `active` the active one.
func simpleSnapshot(_ instance: String = "A", seq: Int, active: Int, tabs: [Int] = [1, 2, 3],
                    audible: Set<Int> = []) -> [String: Any] {
    snapshotObject(instance, seq: seq, [windowObject(1, tabs.map { tabObject($0, active: $0 == active, audible: audible.contains($0)) })])
}

func send(_ store: TabStore, _ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    _ = store.handleMessage(type: object["type"] as! String, payload: data, object: object)
}

func makeStore(stateURL: URL? = nil, on: Bool = true) -> (TabStore, commands: () -> [[String: Any]]) {
    storeCount += 1
    let store = TabStore(stateURL: stateURL ?? stateFolder.appending(path: "state-\(storeCount).json"))
    store.cleanup.clock = { now }
    var commands: [[String: Any]] = []
    store.sendCommand = { commands.append($0) }
    store.cleanup.setOn(on, tabs: store.snapshots)
    return (store, { commands })
}

func closedIds(_ commands: [[String: Any]]) -> [[Int]] {
    commands.filter { $0["action"] as? String == "close" }.map { ($0["tabIds"] as? [Int] ?? []).sorted() }
}

func tabIds(_ store: TabStore, _ instance: String = "A") -> [Int] {
    store.snapshots[instance]?.windows.flatMap(\.tabs).map(\.id) ?? []
}

// MARK: - What cleanup never closes

do {
    let tabs = [
        browserTab(1, active: true),
        browserTab(2),
        browserTab(3, audible: true),
        browserTab(4, pinned: true),
        browserTab(5),
        browserTab(6, noURL: true),
        browserTab(7, url: "favorites://"),
        browserTab(8),
        browserTab(9),
    ]
    let privateTabs = [browserTab(20, window: 2, active: true), browserTab(21, window: 2)]
    let snapshots = ["A": snapshot([browserWindow(1, tabs), browserWindow(2, incognito: true, privateTabs)])]
    var times = Dictionary(uniqueKeysWithValues: (tabs + privateTabs).map { (key($0.id), start) })
    times[key(8)] = start + 23 * hour
    times[key(9)] = nil
    let closing = Set(TabCleanup.tabsToClose(in: snapshots, lastViewed: times, now: start + 25 * hour, after: day, bookmarkTabs: [key(5)]))

    check(closing.contains(key(2)), "a tab nobody has looked at for longer than the setting is closed")
    check(!closing.contains(key(1)), "the active tab in its window is never closed")
    check(!closing.contains(key(3)), "a tab playing sound is never closed")
    check(!closing.contains(key(4)), "a pinned tab is never closed")
    check(!closing.contains(key(5)), "a bookmark's tab is never closed")
    check(!closing.contains(key(6)), "a tab without a URL (Safari hides it without website access) is never closed")
    check(!closing.contains(key(7)), "nor one that isn't a web page, which couldn't be reopened")
    check(!closing.contains(key(8)), "a tab looked at more recently than the setting stays")
    check(!closing.contains(key(9)), "a tab without a clock has only just been seen, and stays")
    check(!closing.contains(key(21)) && !closing.contains(key(20)), "tabs in private windows are never closed")
    check(closing == [key(2)], "and nothing else is closed")
}

do {
    // The bookmark exemption goes through one function, which follows #25's links.
    let (store, _) = makeStore()
    send(store, simpleSnapshot(seq: 1, active: 1))
    let tab = store.tab(for: key(2))!
    let bookmarks = store.bookmarks.count
    store.addBookmark(from: tab, instance: "A")
    check(store.bookmarkTabKeys == [key(2)], "a tab made into a bookmark is that bookmark's tab")
    now = start + 2 * day
    store.runCleanup(after: day)
    check(tabIds(store) == [1, 2], "so cleanup leaves it open and closes the other idle tab")
    if let bookmark = store.bookmarks.last, store.bookmarks.count == bookmarks + 1 {
        store.removeBookmark(bookmark)
    }
    now = start
}

// MARK: - Each interval

do {
    check(CleanupInterval.allCases.map(\.label) == ["12 hours", "1 day", "1 week", "30 days"],
          "Settings offers 12 hours, 1 day, 1 week and 30 days")
    check(CleanupInterval.allCases.map(\.seconds) == [12 * hour, day, 7 * day, 30 * day], "and each is as long as it says")
    let snapshots = ["A": snapshot([browserWindow(1, [browserTab(1, active: true), browserTab(2), browserTab(3)])])]
    let at = start + 60 * day
    for interval in CleanupInterval.allCases {
        let times = [key(1): start, key(2): at - interval.seconds + minute, key(3): at - interval.seconds]
        let closing = TabCleanup.tabsToClose(in: snapshots, lastViewed: times, now: at, after: interval.seconds, bookmarkTabs: [])
        check(!closing.contains(key(2)), "\(interval.label): a tab looked at a minute short of it ago stays")
        check(closing.contains(key(3)), "\(interval.label): a tab last looked at that long ago is closed")
    }
}

do {
    // The setting: off, with 1 day preselected.
    let settings = AppSettings()
    check(settings.closesUnviewedTabs == false, "cleanup is off by default")
    check(settings.unviewedTabInterval == .oneDay, "1 day is preselected")
}

// MARK: - The clocks

do {
    // A tab's clock starts when it stops being active, or when Side Tabs first sees it.
    now = start
    let (store, commands) = makeStore()
    send(store, simpleSnapshot(seq: 1, active: 1))
    check(store.cleanup.lastViewed == [key(1): start, key(2): start, key(3): start], "every tab's clock starts when it's first seen")

    now = start + 10 * hour
    send(store, ["type": "activated", "instance": "A", "windowId": 1, "tabId": 2, "seq": 2])
    check(store.cleanup.lastViewed[key(1)] == start + 10 * hour, "the tab Safari left starts its clock when it stops being active")
    check(store.cleanup.lastViewed[key(3)] == start, "a tab that wasn't looked at keeps its clock")

    now = start + 11 * hour
    send(store, simpleSnapshot(seq: 3, active: 2, tabs: [1, 2, 3, 4]))
    check(store.cleanup.lastViewed[key(4)] == start + 11 * hour, "a tab opened later starts its clock when it's first seen")

    now = start + 12 * hour
    store.runCleanup(after: 12 * hour)
    check(closedIds(commands()) == [[3]], "after 12 hours only the tab nobody looked at all along is closed")
    check(store.cleanup.lastViewed[key(3)] == nil, "a closed tab's clock is dropped")

    now = start + 40 * hour
    store.runCleanup(after: 12 * hour)
    check(closedIds(commands()) == [[3], [1, 4]], "later, the tabs whose clocks ran out are closed too")
    check(tabIds(store) == [2], "the active tab stays however long it's been active")
    check(store.cleanup.lastViewed[key(2)] == start + 40 * hour, "a tab that's still active was looked at as of each run")

    now = start + 41 * hour
    send(store, simpleSnapshot(seq: 4, active: 5, tabs: [2, 5]))
    check(store.cleanup.lastViewed[key(2)] == start + 41 * hour, "a switch seen in a snapshot starts the left tab's clock too")
    now = start
}

do {
    // A tab playing sound is in use: pausing a podcast that played for hours doesn't close its tab.
    now = start
    let (store, commands) = makeStore()
    send(store, simpleSnapshot(seq: 1, active: 1, audible: [2]))
    now = start + 3 * day
    store.runCleanup(after: day)
    check(closedIds(commands()) == [[3]], "a tab playing sound isn't closed")
    now = start + 3 * day + hour
    send(store, simpleSnapshot(seq: 2, active: 1))
    check(store.cleanup.lastViewed[key(2)] == start + 3 * day + hour, "its clock starts when the sound stops")
    now = start + 3 * day + 2 * hour
    store.runCleanup(after: day)
    check(closedIds(commands()) == [[3]], "so it isn't closed right after")
    now = start
}

do {
    // Private windows: no clocks, so nothing from private browsing is kept.
    now = start
    let (store, commands) = makeStore()
    send(store, snapshotObject(seq: 1, [
        windowObject(1, [tabObject(1, active: true), tabObject(2)]),
        windowObject(2, incognito: true, [tabObject(3, window: 2, active: true), tabObject(4, window: 2)]),
    ]))
    check(store.cleanup.lastViewed.keys.allSatisfy { $0.tabId < 3 }, "a private window's tabs get no clock")
    now = start + 40 * day
    store.runCleanup(after: day)
    check(closedIds(commands()) == [[2]], "and are never closed")
    check(store.cleanup.closedTabs.map(\.url) == ["https://example.com/2"], "so the list never holds one")
    now = start
}

do {
    // The clocks only run while cleanup is on. Turned on, every clock starts then, so nothing that was
    // idle before closes at once.
    now = start
    let (store, commands) = makeStore(on: false)
    send(store, simpleSnapshot(seq: 1, active: 1))
    check(store.cleanup.lastViewed.isEmpty, "no clocks while cleanup is off")
    now = start + 10 * day
    store.runCleanup(after: day)
    check(closedIds(commands()).isEmpty, "and nothing is closed")
    store.cleanup.setOn(true, tabs: store.snapshots)
    check(store.cleanup.lastViewed == [key(1): now, key(2): now, key(3): now], "turned on, every tab's clock starts then")
    store.runCleanup(after: day)
    check(closedIds(commands()).isEmpty, "so nothing closes the moment it's turned on")
    now = start + 11 * day
    store.runCleanup(after: day)
    check(closedIds(commands()) == [[2, 3]], "but a day later the idle tabs are closed")
    store.cleanup.setOn(false, tabs: store.snapshots)
    check(store.cleanup.lastViewed.isEmpty, "turned off, the clocks are dropped")
    check(store.cleanup.closedTabs.count == 2, "and the list is kept")
    now = start
}

do {
    // Not while a tab is being renamed: its row would go away under the text field.
    now = start
    let (store, commands) = makeStore()
    send(store, simpleSnapshot(seq: 1, active: 1))
    store.beginRename(.tab(key(2)))
    now = start + 2 * day
    store.runCleanup(after: day)
    check(closedIds(commands()).isEmpty, "nothing is closed while a tab is being renamed")
    store.cancelRename()
    store.runCleanup(after: day)
    check(closedIds(commands()) == [[2, 3]], "the next run closes the idle tabs")
    now = start
}

do {
    // The clocks are saved in state.json, so a quick restart of Side Tabs (an update) doesn't reset them.
    // (Loading compares when they were saved with the real clock, so this runs on today's date.)
    let t0 = Date() - day
    now = t0
    let stateURL = stateFolder.appending(path: "restart.json")
    let (first, _) = makeStore(stateURL: stateURL)
    send(first, simpleSnapshot(seq: 1, active: 1))
    now = t0 + 20 * hour
    send(first, simpleSnapshot(seq: 2, active: 2))
    now = Date() - 30
    first.save()

    let (second, commands) = makeStore(stateURL: stateURL)
    check(second.cleanup.lastViewed == [key(1): t0 + 20 * hour, key(2): t0 + 20 * hour, key(3): t0],
          "the clocks come back after a quick restart of Side Tabs")
    send(second, simpleSnapshot(seq: 5, active: 2))
    check(second.cleanup.lastViewed[key(3)] == t0, "the same Safari's tabs keep their clocks")
    now = t0 + 24 * hour
    second.runCleanup(after: day)
    check(closedIds(commands()) == [[3]], "so a tab idle since before the restart closes on time")
    now = start
}

do {
    // Longer away, every clock starts over, as when cleanup is turned on: while Side Tabs isn't running,
    // tabs can be looked at without it seeing.
    check(TabCleanup.clocksStillHold(savedAt: start, now: start + 30), "clocks saved half a minute before Side Tabs starts hold")
    check(TabCleanup.clocksStillHold(savedAt: start, now: start + TabCleanup.restartAllowance), "and so do clocks a few minutes old")
    check(!TabCleanup.clocksStillHold(savedAt: start, now: start + TabCleanup.restartAllowance + 1), "but not older ones")
    check(!TabCleanup.clocksStillHold(savedAt: nil, now: start), "nor clocks saved without a time")

    let t0 = Date() - 3 * day
    now = t0
    let stateURL = stateFolder.appending(path: "away.json")
    let (first, _) = makeStore(stateURL: stateURL)
    send(first, simpleSnapshot(seq: 1, active: 1))
    first.cleanup.record([closedTab(1, closedAt: Date() - hour)])
    now = Date() - 10 * minute
    first.save()

    now = Date()
    let (second, commands) = makeStore(stateURL: stateURL)
    check(second.cleanup.lastViewed.isEmpty, "after ten minutes away, the saved clocks are dropped")
    check(second.cleanup.closedTabs.map(\.title) == ["Page 1"], "but the list is kept")
    send(second, simpleSnapshot(seq: 5, active: 1))
    check(second.cleanup.lastViewed == [key(1): now, key(2): now, key(3): now], "every tab's clock starts over as Safari's tabs come in")
    second.runCleanup(after: day)
    check(closedIds(commands()).isEmpty, "so tabs that were idle before Side Tabs quit don't close right after it starts")
    now = start
}

do {
    // Clocks belong to an extension instance: when Safari quits they go, and after Safari restarts, with
    // new tab ids, they start over.
    now = start
    let (store, commands) = makeStore()
    send(store, simpleSnapshot(seq: 1, active: 1))
    now = start + 5 * day
    store.safariDidTerminate()
    check(store.cleanup.lastViewed.isEmpty, "Safari quitting drops its clocks")
    send(store, simpleSnapshot("B", seq: 1, active: 7, tabs: [7, 8]))
    check(store.cleanup.lastViewed == [key(7, "B"): now, key(8, "B"): now], "the restarted Safari's tabs start new clocks")
    store.runCleanup(after: day)
    check(closedIds(commands()).isEmpty, "so nothing closes right after Safari restarts")
    now = start
}

do {
    // Clocks saved for an instance that never reports again (Safari quit while Side Tabs wasn't running)
    // are dropped once every live instance has had time to report. (A quick restart, on today's date, so
    // the saved clocks are taken back at all.)
    let t0 = Date()
    now = t0
    let stateURL = stateFolder.appending(path: "gone.json")
    let (first, _) = makeStore(stateURL: stateURL)
    send(first, simpleSnapshot("old", seq: 1, active: 1))
    first.save()

    now = t0 + hour
    let (second, _) = makeStore(stateURL: stateURL)
    send(second, simpleSnapshot("new", seq: 1, active: 1))
    second.runCleanup(after: day)
    check(second.cleanup.lastViewed.keys.contains(key(2, "old")), "right after launch, an instance that hasn't reported keeps its clocks")
    now = t0 + hour + TabCleanup.instanceGracePeriod
    second.runCleanup(after: day)
    check(!second.cleanup.lastViewed.keys.contains { $0.instance == "old" }, "once every live one has reported, a silent instance's clocks go")
    check(second.cleanup.lastViewed.keys.contains(key(2, "new")), "and the live instance keeps its own")
    now = start
}

// MARK: - What goes on the list

do {
    now = start
    let (store, commands) = makeStore()
    send(store, snapshotObject(seq: 1, profile: "work", [
        windowObject(1, [tabObject(1, active: true), tabObject(2), tabObject(3)]),
        windowObject(2, [tabObject(4, window: 2, active: true), tabObject(5, window: 2)]),
    ]))
    store.beginRename(.tab(key(3)))
    store.commitRename("My name")
    now = start + 2 * day
    store.runCleanup(after: day)
    check(closedIds(commands()) == [[2, 3], [5]], "each window's idle tabs are closed with one command")
    let list = store.cleanup.closedTabs
    check(list.count == 3, "every closed tab goes on the list")
    if let renamed = list.first(where: { $0.url == "https://example.com/3" }) {
        check(renamed.shownTitle == "My name" && renamed.title == "Tab 3", "an entry shows the tab's custom name, and keeps its title")
        check(renamed.faviconURL == "https://example.com/icon-3.png", "and its icon")
        check(renamed.closedAt == now, "and when it was closed")
        check(renamed.profile == "work", "and which profile it came from")
    } else {
        check(false, "the renamed tab is on the list")
    }
    check(list.first(where: { $0.url == "https://example.com/2" })?.shownTitle == "Tab 2", "an entry without a custom name shows the title")

    now = start + 3 * day
    send(store, snapshotObject(seq: 2, profile: "work", [windowObject(1, [tabObject(1, active: true), tabObject(6)])]))
    now = start + 5 * day
    store.runCleanup(after: day)
    check(store.cleanup.closedTabs.first?.url == "https://example.com/6", "newest first")

    store.save()
    let data = (try? Data(contentsOf: stateFolder.appending(path: "state-\(storeCount).json"))) ?? Data()
    let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let savedList = (saved?["cleanup"] as? [String: Any])?["closedTabs"] as? [[String: Any]]
    check(savedList?.first?["url"] as? String == "https://example.com/6", "the list is kept in state.json")
    now = start
}

do {
    // At most 100 tabs, none closed more than 30 days ago, one entry per page.
    let at = start + 100 * day
    let many = (1...120).map { closedTab($0, closedAt: at - Double($0) * minute) }
    let capped = TabCleanup.pruned(many, now: at)
    check(capped.count == TabCleanup.listLimit && TabCleanup.listLimit == 100, "the list keeps at most 100 tabs")
    check(capped.first?.title == "Page 1" && capped.last?.title == "Page 100", "the newest 100")

    let aged = TabCleanup.pruned([
        closedTab(1, closedAt: at - 29 * day),
        closedTab(2, closedAt: at - 30 * day - minute),
    ], now: at)
    check(aged.map(\.title) == ["Page 1"], "a tab closed more than 30 days ago is dropped")

    let added = TabCleanup.list([closedTab(1, closedAt: at - day), closedTab(2, closedAt: at - 2 * day)],
                                adding: [closedTab(3, closedAt: at)], now: at)
    check(added.map(\.title) == ["Page 3", "Page 1", "Page 2"], "newly closed tabs go to the top")

    let again = TabCleanup.list([closedTab(1, closedAt: at - day, url: "https://example.com/same")],
                                adding: [closedTab(2, closedAt: at, url: "https://example.com/same#part")], now: at)
    check(again.map(\.title) == ["Page 2"], "the same page closed again replaces its older entry")

    // Old entries leave a list loaded from state.json too. (Loading prunes it by the real clock, so this
    // one runs on today's date.)
    let today = Date()
    now = today
    let stateURL = stateFolder.appending(path: "aged.json")
    let (first, _) = makeStore(stateURL: stateURL)
    first.cleanup.record([closedTab(1, closedAt: today - day), closedTab(2, closedAt: today - 20 * day)])
    first.save()
    now = today + 15 * day
    let (second, _) = makeStore(stateURL: stateURL)
    second.runCleanup(after: day)
    check(second.cleanup.closedTabs.map(\.title) == ["Page 1"], "entries past 30 days leave the list on the next run")
    now = start
}

do {
    check(TabCleanup.age(of: start, now: start + 30) == "now", "under a minute ago reads \"now\"")
    check(TabCleanup.age(of: start, now: start + 5 * minute + 10) == "5m", "minutes read \"5m\"")
    check(TabCleanup.age(of: start, now: start + 3 * hour + 59 * minute) == "3h", "hours read \"3h\"")
    check(TabCleanup.age(of: start, now: start + 2 * day + 5 * hour) == "2d", "days read \"2d\"")
}

// MARK: - Reopening

/// Profile "home" in instance A (window 1, the current one) and profile "work" in instance B (a private
/// window 4 and window 5, which it focused last).
func twoProfiles() -> (TabStore, commands: () -> [[String: Any]]) {
    let (store, commands) = makeStore()
    send(store, snapshotObject("A", seq: 1, profile: "home", focused: 1, focusChangedAt: 10,
                               [windowObject(1, [tabObject(1, active: true)])]))
    send(store, snapshotObject("B", seq: 1, profile: "work", focused: 5, focusChangedAt: 5, [
        windowObject(4, incognito: true, [tabObject(40, window: 4, active: true)]),
        windowObject(5, [tabObject(50, window: 5, active: true)]),
    ]))
    return (store, commands)
}

func creates(_ commands: [[String: Any]]) -> [[String: Any]] {
    commands.filter { $0["action"] as? String == "create" }
}

do {
    now = start
    let (store, commands) = twoProfiles()
    check(store.currentWindow?.instance == "A", "instance A's window is the current one")
    var work = closedTab(1, closedAt: start)
    work.profile = "work"
    var home = closedTab(2, closedAt: start)
    home.profile = "home"
    var elsewhere = closedTab(3, closedAt: start)
    elsewhere.profile = "gone"
    store.cleanup.record([work, home, elsewhere])

    store.reopen(work)
    var create = creates(commands()).last ?? [:]
    check(create["instance"] as? String == "B" && create["windowId"] as? Int == 5, "a tab reopens in a window of the profile it came from")
    check(create["url"] as? String == work.url, "with its page")
    check(create["focus"] as? Bool == true, "and that window comes forward, since it isn't the current one")
    check(!store.cleanup.closedTabs.contains(work), "and it's taken off the list")

    store.reopen(home)
    create = creates(commands()).last ?? [:]
    check(create["instance"] as? String == "A" && create["windowId"] as? Int == 1, "a tab of the current window's profile opens in the current window")
    check(create["focus"] == nil, "without asking for any window to come forward")

    store.reopen(elsewhere)
    create = creates(commands()).last ?? [:]
    check(create["instance"] as? String == "A" && create["windowId"] as? Int == 1, "with no window of its profile open, it opens in the current window")
    check(store.cleanup.closedTabs.isEmpty, "each reopened tab left the list")
    now = start
}

do {
    // Which window of a profile: the current one if it's the profile's, else the one it focused last,
    // never a private one.
    let snapshots = [
        "A": snapshot(instance: "A", profile: "home", focused: 1, focusChangedAt: 10, [browserWindow(1, []), browserWindow(2, [])]),
        "B": snapshot(instance: "B", profile: "work", focused: -1, lastFocused: 6, focusChangedAt: 5,
                      [browserWindow(5, []), browserWindow(6, []), browserWindow(7, incognito: true, [])]),
        "C": snapshot(instance: "C", profile: "solo", focused: 9, focusChangedAt: 4, [browserWindow(9, incognito: true, [])]),
    ]
    let current = TabCleanup.Window(instance: "A", windowId: 2)
    check(TabCleanup.reopenWindow(forProfile: "home", in: snapshots, current: current) == current,
          "the current window, when it's the profile's")
    check(TabCleanup.reopenWindow(forProfile: "work", in: snapshots, current: current) == TabCleanup.Window(instance: "B", windowId: 6),
          "otherwise the profile's window that was focused last")
    check(TabCleanup.reopenWindow(forProfile: "solo", in: snapshots, current: current) == current,
          "a profile with only a private window open has no window to reopen in")
    check(TabCleanup.reopenWindow(forProfile: "work", in: [:], current: nil) == nil, "with no windows at all, there's nowhere")
}

// MARK: - Copies of the extension that go quiet (#31)

do {
    // A copy that has sent nothing for a while may be stopped, or held up by load, and what it last said may be
    // old: cleanup closes none of its tabs and reopens nothing in its windows. Its clocks are kept, and once it
    // speaks again, its tabs are closed as before.
    now = start
    let (store, commands) = twoProfiles()
    var ahead: TimeInterval = 0
    store.clock = { Date().addingTimeInterval(ahead) }
    send(store, snapshotObject("B", seq: 2, profile: "work", focused: 5, focusChangedAt: 5, [
        windowObject(5, [tabObject(50, window: 5, active: true), tabObject(51, window: 5)]),
    ]))
    ahead = 20
    send(store, ["type": "heartbeat", "instance": "A", "profile": "home", "seq": 1])
    ahead = 31
    store.noteQuietCopies()
    check(store.liveInstances == ["A"], "B, the work profile's copy, is quiet")

    now = start + 2 * day
    store.runCleanup(after: day)
    check(closedIds(commands()).isEmpty, "a quiet copy's tabs aren't closed")
    check(store.cleanup.lastViewed[key(51, "B")] == start, "but keep their clocks")

    var work = closedTab(1, closedAt: start)
    work.profile = "work"
    store.cleanup.record([work])
    store.reopen(work)
    let create = creates(commands()).last ?? [:]
    check(create["instance"] as? String == "A" && create["windowId"] as? Int == 1,
          "a tab of a profile whose copy is quiet reopens in the current window, not in a window of the quiet copy")

    ahead = 32
    send(store, ["type": "heartbeat", "instance": "B", "profile": "work", "seq": 2])
    store.runCleanup(after: day)
    check(closedIds(commands()) == [[51]], "once the copy speaks again, its tab nobody looked at is closed")
    now = start
}

try? FileManager.default.removeItem(at: stateFolder)

if failures == 0 {
    print("tab cleanup checks passed")
} else {
    print("\(failures) tab cleanup check(s) failed")
    exit(1)
}
