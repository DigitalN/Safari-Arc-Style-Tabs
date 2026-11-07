import Foundation

// Checks for TabStore's handling of messages from the extension. Run with scripts/run-checks.sh,
// which compiles this together with the real TabStore.swift and Models.swift.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

let instance = "test-instance"

func tab(_ id: Int, active: Bool = false, windowId: Int = 1) -> [String: Any] {
    ["id": id, "windowId": windowId, "index": id - 1, "title": "Tab \(id)", "url": "https://example.com/\(id)",
     "active": active, "pinned": false, "audible": false, "muted": false, "loading": false]
}

func snapshotObject(seq: Int, active: Int, tabs: [Int] = [1, 2, 3, 4], startedAt: Double? = nil) -> [String: Any] {
    var object: [String: Any] = ["type": "snapshot", "instance": instance, "seq": seq, "focusedWindowId": 1, "lastFocusedWindowId": 1,
     "focusChangedAt": 1.0,
     "windows": [["id": 1, "focused": true, "incognito": false, "tabs": tabs.map { tab($0, active: $0 == active) }]]]
    if let startedAt { object["startedAt"] = startedAt }
    return object
}

/// Lets time pass with the main run loop going, since the store schedules work on it.
func wait(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func send(_ store: TabStore, _ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    _ = store.handleMessage(type: object["type"] as! String, payload: data, object: object)
}

/// The clock the extension stamps its messages with (`Date.now()`): milliseconds since 1970.
func nowMilliseconds() -> Double {
    (Date().timeIntervalSince1970 * 1000).rounded(.down)
}

func activated(_ store: TabStore, tab id: Int, seq: Int? = nil, at: Double? = nil) {
    var object: [String: Any] = ["type": "activated", "instance": instance, "windowId": 1, "tabId": id]
    if let seq { object["seq"] = seq }
    if let at { object["at"] = at }
    send(store, object)
}

func highlighted(_ store: TabStore) -> Int? {
    store.snapshots[instance]?.windows.first?.tabs.first(where: \.active)?.id
}

/// Every store here keeps its bookmarks and names in a folder of its own, never the Mac's real one.
let stateFolder = FileManager.default.temporaryDirectory.appending(path: "side-tabs-store-checks-\(UUID().uuidString)")
var storeCount = 0

func makeStore(active: Int = 1) -> (TabStore, sent: () -> [[String: Any]]) {
    storeCount += 1
    let store = TabStore(stateURL: stateFolder.appending(path: "state-\(storeCount).json"))
    var commands: [[String: Any]] = []
    store.sendCommand = { commands.append($0) }
    send(store, snapshotObject(seq: 1, active: active))
    return (store, { commands })
}

func click(_ store: TabStore, tab id: Int) {
    let tab = store.tab(for: TabKey(instance: instance, tabId: id))!
    store.activate(tab, instance: instance)
}

// MARK: - A stuck pending switch must not freeze the highlight (#17 item 1)

do {
    // Lost switch: the click on tab 3 never produces a report; later Safari goes to tab 2 by itself.
    let (store, _) = makeStore()
    click(store, tab: 3)
    check(highlighted(store) == 3, "click highlights the tab at once")
    activated(store, tab: 2)
    check(highlighted(store) == 3, "a report right after a click on another tab is held back (the first click's report)")
    wait(1.1)
    activated(store, tab: 2)
    check(highlighted(store) == 2, "once the click is stale, Safari's report moves the highlight")
    activated(store, tab: 4)
    check(highlighted(store) == 4, "and the stale click doesn't hold back later reports")
}

do {
    // Stale pending is also dropped by a snapshot, so a late report isn't held back by it.
    let (store, _) = makeStore()
    click(store, tab: 3)
    wait(1.1)
    send(store, snapshotObject(seq: 2, active: 1))
    check(highlighted(store) == 1, "a snapshot after a lost switch shows where Safari is")
    activated(store, tab: 2)
    check(highlighted(store) == 2, "a report after the stale pending was dropped moves the highlight")
}

do {
    // Normal quick double click still works: the first switch's report is ignored while the second is pending.
    let (store, _) = makeStore()
    click(store, tab: 2)
    click(store, tab: 3)
    activated(store, tab: 2)
    check(highlighted(store) == 3, "report for the first of two quick clicks doesn't move the highlight back")
    activated(store, tab: 3)
    check(highlighted(store) == 3, "report for the second click confirms it")
}

// MARK: - Reports that arrive out of order (#17 item 2)

do {
    // An `activated` report numbered below a snapshot already applied is older than it.
    let (store, _) = makeStore()
    send(store, snapshotObject(seq: 5, active: 3))
    activated(store, tab: 2, seq: 4)
    check(highlighted(store) == 3, "a report older than the last snapshot is ignored")
    activated(store, tab: 4, seq: 6)
    check(highlighted(store) == 4, "a report newer than the last snapshot is applied")
}

do {
    // Two reports swapped on the way.
    let (store, _) = makeStore()
    activated(store, tab: 4, seq: 7)
    activated(store, tab: 2, seq: 6)
    check(highlighted(store) == 4, "an older report arriving after a newer one is ignored")
    activated(store, tab: 4, seq: 7)
    check(highlighted(store) == 4, "a repeated report changes nothing")
}

do {
    // The report overtakes the snapshot that was started before it.
    let (store, _) = makeStore()
    activated(store, tab: 4, seq: 8)
    send(store, snapshotObject(seq: 7, active: 2))
    check(highlighted(store) == 4, "a snapshot started before a report doesn't move the highlight back")
    send(store, snapshotObject(seq: 9, active: 1))
    check(highlighted(store) == 1, "a snapshot started after the report is believed")
    activated(store, tab: 3, seq: 10)
    check(highlighted(store) == 3, "and reports after it apply again")
}

do {
    // An older extension page that sends no number still works.
    let (store, _) = makeStore()
    activated(store, tab: 2)
    check(highlighted(store) == 2, "a report without a seq is applied")
    activated(store, tab: 3)
    check(highlighted(store) == 3, "and so is the next one")
}

// MARK: - Switching through the tab bar, with the extension as fallback (#18)

/// Runs `body` with a store whose tab-bar presses are answered by the test, and the commands sent
/// to the extension collected.
func withPresser(
    method: String? = nil,
    activeTab: Int = 1,
    _ body: (TabStore, _ presses: () -> [(target: TabBarTarget, finish: (TabBarPressOutcome) -> Void)], _ commands: () -> [[String: Any]]) -> Void
) {
    // In memory only, so nothing is written to the Mac's preferences.
    if let method {
        UserDefaults.standard.setVolatileDomain(["tabSwitchMethod": method], forName: UserDefaults.argumentDomain)
    }
    defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
    let (store, commands) = makeStore(active: activeTab)
    var presses: [(target: TabBarTarget, finish: (TabBarPressOutcome) -> Void)] = []
    store.pressTab = { target, finish in presses.append((target, finish)) }
    body(store, { presses }, commands)
}

func activations(_ commands: [[String: Any]]) -> [Int] {
    commands.filter { $0["action"] as? String == "activate" }.compactMap { $0["tabId"] as? Int }
}

withPresser { store, presses, commands in
    click(store, tab: 3)
    check(presses().count == 1, "by default a click asks for the tab bar's button")
    check(activations(commands()).isEmpty, "and doesn't send the extension's command yet")
    let target = presses().first?.target
    check(target?.title == "Tab 3" && target?.position == 2, "the target is the clicked tab and where it sits")
    check(target?.windowTitles.compactMap { $0 } == ["Tab 1", "Tab 2", "Tab 3", "Tab 4"], "with the titles of its window's tabs")
    check(highlighted(store) == 3, "the highlight still moves at once")
}

withPresser { store, presses, commands in
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    check(activations(commands()).isEmpty, "a press that worked sends nothing")
    activated(store, tab: 3, seq: 2)
    wait(1.2)
    check(activations(commands()).isEmpty, "and nothing follows once Safari confirms the switch")
}

withPresser { store, presses, commands in
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    wait(1.2)
    check(activations(commands()) == [3], "a press Safari never confirms is followed by the extension's command")
}

withPresser { store, presses, commands in
    click(store, tab: 3)
    presses()[0].finish(.fallback("the window has no tab bar"))
    check(activations(commands()) == [3], "when the press can't be made, the extension's command is sent")
    check(highlighted(store) == 3, "and the highlight stays")
}

withPresser { store, presses, commands in
    click(store, tab: 2)
    click(store, tab: 4)
    presses()[0].finish(.fallback("the buttons don't line up"))
    check(activations(commands()).isEmpty, "a fallback for a click that a newer click replaced sends nothing")
    presses()[1].finish(.fallback("the buttons don't line up"))
    check(activations(commands()) == [4], "the newer click's own fallback does")
}

withPresser { store, presses, commands in
    click(store, tab: 3)
    presses()[0].finish(.superseded)
    check(activations(commands()).isEmpty, "a press that a newer one replaced before it ran sends nothing")
}

withPresser { store, presses, commands in
    click(store, tab: 3)
    activated(store, tab: 3, seq: 2)
    presses()[0].finish(.fallback("Safari didn't answer in time"))
    check(activations(commands()).isEmpty, "a fallback that arrives after Safari confirmed the switch sends nothing")
}

withPresser(method: "push") { store, presses, commands in
    click(store, tab: 3)
    check(presses().isEmpty, "with the setting on push, the tab bar isn't tried")
    check(activations(commands()) == [3], "and the extension's command goes out at once")
}

withPresser(method: "accessibility") { store, presses, commands in
    click(store, tab: 3)
    check(presses().count == 1 && activations(commands()).isEmpty, "the setting can also say accessibility")
}

do {
    // A tab in a window other than the one the sidebar shows can't be pressed in the docked tab bar.
    var object = snapshotObject(seq: 5, active: 1)
    var windows = object["windows"] as! [[String: Any]]
    windows.append(["id": 2, "focused": false, "incognito": false, "tabs": [tab(10, active: true, windowId: 2), tab(11, windowId: 2)]])
    object["windows"] = windows
    withPresser { store, presses, commands in
        send(store, object)
        click(store, tab: 11)
        check(presses().isEmpty, "a tab in another window isn't pressed")
        check(activations(commands()) == [11], "it goes through the extension")
    }
}

// MARK: - Reports from before and after the click (#19 item 1)
//
// The extension stamps each `activated` report with the time it ran (`at`). Anything before the
// click asked for its switch can't be the click's doing; anything after is Safari moving on.

withPresser { store, presses, commands in
    // The failure in the issue: the press took, Safari is slow to confirm, and meanwhile the user
    // picks another tab in Safari. The one-second command must not drag Safari back to tab 3.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    wait(0.3)
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    check(highlighted(store) == 2, "a switch Safari made after the click moves the highlight there")
    wait(1.2)
    check(activations(commands()).isEmpty, "and the click's one-second command is cancelled, so it can't undo that switch")
    activated(store, tab: 4, seq: 3, at: nowMilliseconds())
    check(highlighted(store) == 4, "later reports follow Safari too")
}

withPresser { store, presses, commands in
    // The same, without the tab-bar press: the extension's command is already out and nothing is waiting.
    click(store, tab: 3)
    presses()[0].finish(.fallback("the window has no tab bar"))
    activated(store, tab: 1, seq: 2, at: nowMilliseconds())
    check(highlighted(store) == 1, "after the extension's command is sent, Safari moving on still moves the highlight")
}

withPresser { store, presses, commands in
    // A report from before the click describes a switch the click didn't make, even for the very
    // tab that was clicked: it doesn't answer the click, so the one-second command stays.
    let earlier = nowMilliseconds() - 50
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: earlier)
    check(highlighted(store) == 3, "a report from before the click for the clicked tab leaves the highlight there")
    wait(1.2)
    check(activations(commands()) == [3], "but doesn't count as Safari confirming the click")
}

withPresser { store, presses, commands in
    // ...and a report from before the click for another tab doesn't undo the click's highlight.
    let earlier = nowMilliseconds() - 50
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 2, seq: 2, at: earlier)
    check(highlighted(store) == 3, "a report from before the click for another tab doesn't move the highlight back")
    wait(1.2)
    check(activations(commands()) == [3], "and the click is still being waited for")
}

withPresser { store, presses, commands in
    // Two quick clicks. The report for the first can reach the app after the second click even
    // though the extension stamped it a moment after it, because the stamp is when its page ran
    // the event, not when Safari switched. The first click's tab is still its own switch.
    click(store, tab: 2)
    click(store, tab: 4)
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    check(highlighted(store) == 4, "a late report for an earlier click's tab doesn't move the highlight back")
    presses()[1].finish(.pressed(milliseconds: 4))
    activated(store, tab: 4, seq: 3, at: nowMilliseconds())
    wait(1.2)
    check(activations(commands()).isEmpty, "and the second click is confirmed by its own report")
}

withPresser { store, presses, commands in
    // Reports without a stamp (an extension page from before this change) keep working as before.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 2, seq: 2)
    check(highlighted(store) == 3, "an unstamped report for another tab is taken as an earlier click's")
    activated(store, tab: 3, seq: 3)
    wait(1.2)
    check(activations(commands()).isEmpty, "an unstamped report for the clicked tab confirms it")
}

// MARK: - Snapshots from before the click (#19 item 2)
//
// The extension stamps each snapshot with the time its build started (`startedAt`). One started
// before the click asked for its switch shows the state the click is about to change.

do {
    // The blink in the issue: a snapshot started just before the click arrives just after it.
    let (store, _) = makeStore()
    let earlier = nowMilliseconds() - 50
    click(store, tab: 3)
    send(store, snapshotObject(seq: 2, active: 1, startedAt: earlier))
    check(highlighted(store) == 3, "a snapshot started before the click doesn't move the highlight back to the old tab")
    activated(store, tab: 3, seq: 3, at: nowMilliseconds())
    check(highlighted(store) == 3, "and the report for the clicked tab confirms it")
}

withPresser { store, presses, commands in
    // It also doesn't stand for Safari having made the switch.
    let earlier = nowMilliseconds() - 50
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    send(store, snapshotObject(seq: 2, active: 3, startedAt: earlier))
    check(highlighted(store) == 3, "a snapshot started before the click that shows the clicked tab leaves the highlight there")
    wait(1.2)
    check(activations(commands()) == [3], "but it isn't Safari's answer to the click, so the one-second command stays")
}

withPresser { store, presses, commands in
    // A snapshot started after the click is believed, and one that shows the clicked tab confirms it.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    send(store, snapshotObject(seq: 2, active: 3, startedAt: nowMilliseconds()))
    wait(1.2)
    check(activations(commands()).isEmpty, "a snapshot started after the click that shows the clicked tab confirms it")
}

do {
    // A snapshot older than the click only holds the highlight while the click is still being waited for.
    let (store, _) = makeStore()
    let earlier = nowMilliseconds() - 50
    click(store, tab: 3)
    wait(1.1)
    send(store, snapshotObject(seq: 2, active: 1, startedAt: earlier))
    check(highlighted(store) == 1, "once the click is stale, even an older snapshot shows where Safari is")
}

do {
    // A snapshot without a stamp (an extension page from before this change) is applied as before.
    let (store, _) = makeStore()
    click(store, tab: 3)
    send(store, snapshotObject(seq: 2, active: 1))
    check(highlighted(store) == 1, "an unstamped snapshot is believed")
}

do {
    // A snapshot for another window or profile has nothing to say about this click.
    let (store, _) = makeStore()
    let earlier = nowMilliseconds() - 50
    click(store, tab: 3)
    var other = snapshotObject(seq: 1, active: 2, startedAt: earlier)
    other["instance"] = "other-instance"
    send(store, other)
    check(highlighted(store) == 3, "a snapshot of another extension instance doesn't touch this click's highlight")
    check(store.snapshots["other-instance"]?.windows.first?.tabs.first(where: \.active)?.id == 2, "and is applied as it is")
}

do {
    // A report held back because a click is waiting for another tab mustn't come back through a
    // snapshot that was started before the report.
    let (store, _) = makeStore()
    click(store, tab: 2)
    click(store, tab: 3)
    activated(store, tab: 2, seq: 5, at: nowMilliseconds())
    check(highlighted(store) == 3, "the earlier click's report is held back")
    send(store, snapshotObject(seq: 4, active: 3, startedAt: nowMilliseconds()))
    check(highlighted(store) == 3, "and a snapshot started before that report doesn't bring it back")
}

try? FileManager.default.removeItem(at: stateFolder)

if failures == 0 {
    print("store checks passed")
} else {
    print("\(failures) store check(s) failed")
    exit(1)
}
