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
///
/// With `reading: true`, reads of Safari's selected tab (`selectionReads`) are answered by the test too;
/// without it the store can't ask, and takes the extension's messages as it always did.
func withPresser(
    activeTab: Int = 1,
    reading: Bool = false,
    _ body: (TabStore, _ presses: () -> [(target: TabBarTarget, finish: (TabBarPressOutcome) -> Void)], _ commands: () -> [[String: Any]]) -> Void
) {
    let (store, commands) = makeStore(active: activeTab)
    var presses: [(target: TabBarTarget, finish: (TabBarPressOutcome) -> Void)] = []
    store.pressTab = { target, finish in presses.append((target, finish)) }
    selectionReads = []
    if reading {
        store.checkSelection = { titles, finish in selectionReads.append((titles, finish)) }
    }
    body(store, { presses }, commands)
}

/// The reads of Safari's selected tab the store asked for, with the titles it gave and how to answer.
nonisolated(unsafe) var selectionReads: [(titles: [String?], finish: (TabBarSelection) -> Void)] = []

func activations(_ commands: [[String: Any]]) -> [Int] {
    commands.filter { $0["action"] as? String == "activate" }.compactMap { $0["tabId"] as? Int }
}

func snapshotRequests(_ commands: [[String: Any]]) -> Int {
    commands.filter { $0["action"] as? String == "snapshot" }.count
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
    check(activations(commands()).isEmpty, "a press Safari doesn't confirm in time is not followed by a command that could pull Safari back (#20 item 3)")
    check(snapshotRequests(commands()) == 1, "Safari is asked where it is instead")
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
    check(snapshotRequests(commands()) == 1, "but doesn't count as Safari confirming the click, so Safari is asked where it is")
}

withPresser { store, presses, commands in
    // ...and a report from before the click for another tab doesn't undo the click's highlight.
    let earlier = nowMilliseconds() - 50
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 2, seq: 2, at: earlier)
    check(highlighted(store) == 3, "a report from before the click for another tab doesn't move the highlight back")
    wait(1.2)
    check(snapshotRequests(commands()) == 1, "and the click is still being waited for")
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
    check(snapshotRequests(commands()) == 1, "but it isn't Safari's answer to the click, so Safari is asked where it is")
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
    // A snapshot started before the click shows the state the click replaced, however late it arrives (#22 item 3).
    let (store, _) = makeStore()
    let earlier = nowMilliseconds() - 50
    click(store, tab: 3)
    wait(1.1)
    send(store, snapshotObject(seq: 2, active: 1, startedAt: earlier))
    check(highlighted(store) == 3, "even after the first second, a snapshot started before the click doesn't move the highlight")
    send(store, snapshotObject(seq: 3, active: 1, startedAt: nowMilliseconds()))
    check(highlighted(store) == 1, "but one started after it, once the click is no longer waited for, shows where Safari is")
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

// MARK: - What the live test of the branch found (#20)

withPresser { store, presses, commands in
    // Item 3: under load the extension's reports come seconds late. Two clicks 1.2 s apart, both
    // pressed, no report in time: the first click's one-second command used to be sent, run
    // after the second click, and put Safari back on the first tab.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    wait(1.2)
    click(store, tab: 4)
    presses()[1].finish(.pressed(milliseconds: 4))
    wait(1.2)
    check(activations(commands()).isEmpty, "no command is ever sent for a click whose press worked, so none can run late and undo a newer click")
}

withPresser { store, presses, commands in
    // ...and when Safari's report finally arrives, it is believed as before.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    wait(1.2)
    activated(store, tab: 3, seq: 2, at: nowMilliseconds() - 1000)
    check(highlighted(store) == 3, "a late report for the clicked tab keeps the highlight there")
}

do {
    // Item 4: a snapshot that started after the click but before Safari switched shows the old tab.
    let (store, _) = makeStore()
    click(store, tab: 3)
    send(store, snapshotObject(seq: 2, active: 1, startedAt: nowMilliseconds()))
    check(highlighted(store) == 3, "a snapshot started after the click that still shows the old tab doesn't move the highlight")
    send(store, snapshotObject(seq: 3, active: 1, startedAt: nowMilliseconds()))
    check(highlighted(store) == 3, "nor does the next one while the click is waiting")
    activated(store, tab: 3, seq: 4, at: nowMilliseconds())
    check(highlighted(store) == 3, "and Safari's report for the clicked tab settles it")
    send(store, snapshotObject(seq: 5, active: 3, startedAt: nowMilliseconds()))
    check(highlighted(store) == 3, "with nothing left to hold back")
}

do {
    // The same without Accessibility: a click while another app is in front makes Safari take
    // focus, which sends a snapshot at once.
    let (store, commands) = makeStore()
    click(store, tab: 2)
    send(store, snapshotObject(seq: 2, active: 1, startedAt: nowMilliseconds()))
    check(highlighted(store) == 2, "a snapshot sent by Safari coming forward doesn't blink the highlight back")
    wait(1.2)
    check(snapshotRequests(commands()) == 1, "if Safari never confirms, it is asked where it is")
    send(store, snapshotObject(seq: 3, active: 1, startedAt: nowMilliseconds()))
    check(highlighted(store) == 1, "and the answer is believed")
}

do {
    // A snapshot may not hold the highlight on a tab that is gone.
    let (store, _) = makeStore()
    click(store, tab: 3)
    send(store, snapshotObject(seq: 2, active: 1, tabs: [1, 2, 4], startedAt: nowMilliseconds()))
    check(highlighted(store) == 1, "a snapshot without the clicked tab (closed meanwhile) is believed")
    activated(store, tab: 2, seq: 3, at: nowMilliseconds())
    check(highlighted(store) == 2, "and the closed tab's click isn't waited for any longer")
}

do {
    // Safari moving on after the click still wins: its report arrives ahead of the snapshot, and
    // ends the wait.
    let (store, _) = makeStore()
    click(store, tab: 3)
    wait(0.1)
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    check(highlighted(store) == 2, "Safari's own report of another tab moves the highlight")
    send(store, snapshotObject(seq: 3, active: 2, startedAt: nowMilliseconds()))
    check(highlighted(store) == 2, "and the snapshot after it agrees")
}

withPresser { store, presses, commands in
    // Item 5: two tabs clicked in turn, every report arriving late (under load, the extension's
    // page runs its listener seconds after Safari switched). A report that belongs to an earlier
    // click mustn't confirm a later click on the same tab, or move the highlight off the newest.
    click(store, tab: 3)    // A
    click(store, tab: 2)    // B
    click(store, tab: 3)    // A again
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())    // the first click on A
    click(store, tab: 2)    // B again
    check(highlighted(store) == 2, "the newest click holds the highlight")
    activated(store, tab: 2, seq: 3, at: nowMilliseconds())    // the first click on B
    check(highlighted(store) == 2, "a late report for an earlier click on the newest tab doesn't confirm it")
    activated(store, tab: 3, seq: 4, at: nowMilliseconds())    // the second click on A
    check(highlighted(store) == 2, "a late report for an earlier click on the other tab doesn't move the highlight (no \"Safari switched to another tab\")")
    activated(store, tab: 2, seq: 5, at: nowMilliseconds())    // the second click on B
    check(highlighted(store) == 2, "the newest click's own report confirms it")
    presses()[3].finish(.pressed(milliseconds: 4))
    wait(1.2)
    check(activations(commands()).isEmpty && snapshotRequests(commands()) == 0, "and nothing is sent once everything is confirmed")
}

withPresser { store, presses, commands in
    // Item 5, the case from the issue: the first click on A's report arrives and is taken for the
    // second click's own; the second click's report then arrives after the click on B.
    click(store, tab: 3)    // A
    click(store, tab: 2)    // B
    click(store, tab: 3)    // A again
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())    // belongs to the first click on A
    click(store, tab: 2)    // B again
    activated(store, tab: 3, seq: 3, at: nowMilliseconds())    // belongs to the second click on A
    check(highlighted(store) == 2, "the second click on A's report, arriving after the click on B, isn't Safari moving on")
}

withPresser { store, presses, commands in
    // Reports for tabs the sidebar asked for are matched one to one with its clicks, so a second
    // report for a tab it asked for once really is Safari moving on.
    click(store, tab: 3)
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    click(store, tab: 2)
    activated(store, tab: 3, seq: 3, at: nowMilliseconds())
    check(highlighted(store) == 3, "a report for a tab clicked once, already answered, is Safari going there itself")
}

withPresser { store, presses, commands in
    // The wait for a click is one second, but the click is remembered much longer: the extension
    // can be that late.
    click(store, tab: 3)
    wait(1.2)
    click(store, tab: 2)
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    check(highlighted(store) == 2, "a report that fits a click made a second ago is still its answer, not Safari moving on")
}

withPresser { store, presses, commands in
    // Item 6, as decided by Safari (#22 item 1): the sidebar's highlight can be wrong, so a click
    // on the tab it shows as active is asked of Safari too. Safari's own tab bar does nothing for
    // the tab that's already selected, and neither does this.
    click(store, tab: 1)
    check(presses().count == 1, "a click on the tab shown as active still asks the tab bar, because the highlight can be wrong")
    check(commands().isEmpty, "and sends nothing yet")
    presses()[0].finish(.alreadySelected)
    check(commands().isEmpty, "Safari already shows the tab: nothing is sent")
    check(highlighted(store) == 1, "and the highlight stays on it")
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    check(highlighted(store) == 2, "nothing is waited for, so Safari's next switch moves the highlight")
    wait(1.2)
    check(commands().isEmpty, "and nothing follows a second later: no snapshot request, no command")
}

withPresser { store, presses, commands in
    // The case from the retest: the highlight went back to tab 1 while Safari showed tab 3. The
    // click on tab 1 used to do nothing at all.
    click(store, tab: 1)
    presses()[0].finish(.pressed(milliseconds: 4))
    check(commands().isEmpty, "a click on the tab shown as active is pressed when Safari isn't on it")
    activated(store, tab: 1, seq: 2, at: nowMilliseconds())
    wait(1.2)
    check(commands().isEmpty && highlighted(store) == 1, "and Safari's report settles it as for any click")
}

withPresser { store, presses, commands in
    // The highlight is on tab 3, Safari is on tab 1, and tab 1 is clicked: that is a switch the sidebar
    // didn't know it needed. If Safari says it's already there, the highlight just corrects itself.
    send(store, snapshotObject(seq: 5, active: 3))
    click(store, tab: 1)
    check(highlighted(store) == 1, "the highlight moves to the clicked tab")
    presses()[0].finish(.alreadySelected)
    check(highlighted(store) == 1 && commands().isEmpty, "and stays there when Safari is already on it")
    wait(1.2)
    check(commands().isEmpty, "with no check a second later either")
}

withPresser { store, presses, commands in
    // The press can't be made for a tab shown as active: the extension's command is the fallback, and
    // for a tab Safari is already on it does no harm.
    click(store, tab: 1)
    presses()[0].finish(.fallback("the window has no tab bar"))
    check(activations(commands()) == [1], "the fallback command is sent for the tab shown as active too")
}

withPresser { store, presses, commands in
    // The answer for a click that a newer click replaced is dropped like any other late answer.
    click(store, tab: 1)
    click(store, tab: 3)
    presses()[0].finish(.alreadySelected)
    check(highlighted(store) == 3, "the older click's answer doesn't move the highlight back")
    presses()[1].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    wait(1.2)
    check(commands().isEmpty, "and the newer click is still confirmed by its own report")
}

// MARK: - Late messages after a click was confirmed (#22 item 2)
//
// Under extreme load the extension runs its listeners seconds late, so reports of old clicks arrive after
// a newer click was confirmed, and look like Safari moving on by itself. Safari's tab bar, read through
// Accessibility, stays fast: a message that would move the highlight off the clicked tab asks it.

withPresser(reading: true) { store, presses, commands in
    // The retest: click 3, then 2; 2 is confirmed; then the late report for the first click arrives.
    click(store, tab: 3)
    click(store, tab: 2)
    presses()[1].finish(.pressed(milliseconds: 4))
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    check(highlighted(store) == 2, "the newer click is confirmed")
    activated(store, tab: 3, seq: 3, at: nowMilliseconds())
    check(highlighted(store) == 2, "the late report for the replaced click doesn't move the highlight, even with nothing pending")
    check(selectionReads.count == 1, "but a click whose report was lost leaves its ask behind, so Safari is asked what it shows")
    selectionReads[0].finish(.tab(position: 1))
    check(highlighted(store) == 2, "Safari is on tab 2: the report was old")
    wait(1.2)
    check(commands().isEmpty, "and nothing is sent")
}

withPresser(reading: true) { store, presses, commands in
    // A click on tab 3 whose report was lost (its ask is still remembered), and tab 3 later is where Safari goes by itself.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    click(store, tab: 2)
    presses()[1].finish(.pressed(milliseconds: 4))
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    activated(store, tab: 3, seq: 3, at: nowMilliseconds())
    check(highlighted(store) == 2, "it can't be told from the late report of the click on tab 3, so the highlight waits")
    selectionReads[0].finish(.tab(position: 2))
    check(highlighted(store) == 3, "until Safari says it is on tab 3")
}

withPresser(reading: true) { store, presses, commands in
    // ...and when Safari can't say, such a report stays held back (it most likely answers an old click).
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    click(store, tab: 2)
    presses()[1].finish(.pressed(milliseconds: 4))
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    activated(store, tab: 3, seq: 3, at: nowMilliseconds())
    selectionReads[0].finish(.unknown("2 buttons for 4 tabs"))
    check(highlighted(store) == 2, "an answer of \"can't tell\" leaves it held back")
    send(store, snapshotObject(seq: 4, active: 3, startedAt: nowMilliseconds()))
    selectionReads.last?.finish(.unknown("2 buttons for 4 tabs"))
    check(highlighted(store) == 3, "and the next snapshot, started after the click, shows where Safari is")
}

withPresser(reading: true) { store, presses, commands in
    // A report that answers no click the sidebar remembers (the ask expired), after the click was confirmed.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    activated(store, tab: 4, seq: 3, at: nowMilliseconds())
    check(highlighted(store) == 3, "a report of a switch to another tab doesn't move the highlight at once")
    check(selectionReads.count == 1, "it asks Safari's tab bar which tab is selected")
    check(selectionReads.first?.titles.compactMap { $0 } == ["Tab 1", "Tab 2", "Tab 3", "Tab 4"], "with the titles of the window's tabs")
    selectionReads[0].finish(.tab(position: 2))
    check(highlighted(store) == 3, "Safari is on the clicked tab: the highlight stays, as the late report was old")
    activated(store, tab: 4, seq: 4, at: nowMilliseconds())
    selectionReads[1].finish(.tab(position: 3))
    check(highlighted(store) == 4, "when Safari really did move on, the highlight follows its answer")
    wait(1.2)
    check(commands().isEmpty, "and nothing was sent")
}

withPresser(reading: true) { store, presses, commands in
    // Safari can't say: the report is taken as it was before the check existed.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    activated(store, tab: 4, seq: 3, at: nowMilliseconds())
    selectionReads[0].finish(.unknown("2 buttons for 4 tabs"))
    check(highlighted(store) == 4, "when the tab bar can't be mapped to the tabs, the report moves the highlight after all")
    send(store, snapshotObject(seq: 4, active: 2))
    check(highlighted(store) == 2, "and the sidebar follows Safari from there")
}

withPresser(reading: true) { store, presses, commands in
    // Only the newest word counts: a click or a report since the question makes its answer old.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    activated(store, tab: 4, seq: 3, at: nowMilliseconds())
    click(store, tab: 2)
    selectionReads[0].finish(.tab(position: 3))
    check(highlighted(store) == 2, "an answer that comes after a newer click is dropped")
    presses()[1].finish(.pressed(milliseconds: 4))
    activated(store, tab: 2, seq: 4, at: nowMilliseconds())

    activated(store, tab: 4, seq: 5, at: nowMilliseconds())
    let first = selectionReads.count - 1
    activated(store, tab: 1, seq: 6, at: nowMilliseconds())
    selectionReads[first].finish(.tab(position: 3))
    check(highlighted(store) == 2, "and so is one that comes after a newer report")
    selectionReads[first + 1].finish(.tab(position: 0))
    check(highlighted(store) == 1, "the newest report's own answer is used")
}

withPresser(reading: true) { store, presses, commands in
    // A report stamped before the sidebar put the window on its tab describes a state it has replaced.
    let earlier = nowMilliseconds() - 50
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    activated(store, tab: 2, seq: 3, at: earlier)
    check(highlighted(store) == 3, "a report from before the click doesn't move the highlight")
    check(selectionReads.isEmpty, "and needs no question: it is older than what the sidebar knows")
}

withPresser(reading: true) { store, presses, commands in
    // Item 1's pending click, answered by Safari instead of the extension: Safari moved on after the press.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    wait(0.1)
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    check(highlighted(store) == 3 && selectionReads.count == 1, "Safari seems to have moved on after the click: the tab bar is asked first")
    selectionReads[0].finish(.tab(position: 1))
    check(highlighted(store) == 2, "it says tab 2, and the highlight goes there")
    wait(1.2)
    check(commands().isEmpty, "the click isn't waited for any more: no snapshot request")
}

withPresser(reading: true) { store, presses, commands in
    // ...or Safari is on the clicked tab after all, and the report was old.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    wait(0.1)
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    selectionReads[0].finish(.tab(position: 2))
    check(highlighted(store) == 3, "the highlight stays on the clicked tab")
    wait(1.2)
    check(commands().isEmpty, "and Safari's answer was the confirmation, so nothing is asked a second later")
}

withPresser(reading: true) { store, presses, commands in
    // The press fell back and the extension's command is on its way: Safari is still on the old tab,
    // so the tab bar says that, and the highlight must not go back to it.
    click(store, tab: 3)
    presses()[0].finish(.fallback("the window has no tab bar"))
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    selectionReads[0].finish(.tab(position: 0))
    check(highlighted(store) == 3, "while the extension's command is on its way, the old tab is not where the click is going")
    activated(store, tab: 3, seq: 3, at: nowMilliseconds())
    check(highlighted(store) == 3, "and the command's own report confirms it")
    wait(1.2)
    check(snapshotRequests(commands()) == 0, "with nothing asked a second later")
}

do {
    // Another window than the one the sidebar shows can't be read from the docked window's tab bar.
    var object = snapshotObject(seq: 5, active: 1)
    var windows = object["windows"] as! [[String: Any]]
    windows.append(["id": 2, "focused": false, "incognito": false, "tabs": [tab(10, active: true, windowId: 2), tab(11, windowId: 2), tab(12, windowId: 2)]])
    object["windows"] = windows
    withPresser(reading: true) { store, presses, commands in
        send(store, object)
        click(store, tab: 11)
        func report(tab id: Int, seq: Int) {
            send(store, ["type": "activated", "instance": instance, "windowId": 2, "tabId": id, "seq": seq, "at": nowMilliseconds()])
        }
        report(tab: 11, seq: 6)
        report(tab: 12, seq: 7)
        check(selectionReads.isEmpty, "nothing is read for a window the sidebar isn't docked to")
        let other = store.snapshots[instance]?.windows.first(where: { $0.id == 2 })?.tabs.first(where: \.active)?.id
        check(other == 12, "its report is taken as it always was")
    }
}

// MARK: - Old snapshots, and a one-second check that can't be starved (#22 item 3)
//
// Under load a snapshot arrives seconds after the extension started building it. Once the click is
// confirmed nothing holds the highlight against it, and it used to be believed.

withPresser(reading: true) { store, presses, commands in
    // The first second is over, the click was confirmed, and a snapshot started before the click arrives.
    let earlier = nowMilliseconds() - 50
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    wait(1.1)
    send(store, snapshotObject(seq: 3, active: 1, startedAt: earlier))
    check(highlighted(store) == 3, "a snapshot started before the click doesn't move the highlight, even after the click was confirmed")
    check(selectionReads.isEmpty, "it is older than what the sidebar knows, so Safari isn't asked")
    send(store, snapshotObject(seq: 4, active: 2, tabs: [1, 2, 4], startedAt: earlier))
    check(highlighted(store) == 2, "unless the clicked tab is gone from the window: then the snapshot is believed")
}

withPresser(reading: true) { store, presses, commands in
    // A snapshot started after the click that shows another tab: right, or built before the switch took effect.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    wait(1.1)
    send(store, snapshotObject(seq: 3, active: 1, startedAt: nowMilliseconds()))
    check(highlighted(store) == 3, "a snapshot that shows another tab doesn't move the highlight by itself")
    check(selectionReads.count == 1, "it asks Safari's tab bar which tab is selected")
    selectionReads[0].finish(.tab(position: 2))
    check(highlighted(store) == 3, "Safari is on the clicked tab: the snapshot was wrong")
    send(store, snapshotObject(seq: 4, active: 1, startedAt: nowMilliseconds()))
    selectionReads[1].finish(.tab(position: 0))
    check(highlighted(store) == 1, "when Safari is on the other tab, the highlight goes there")
    send(store, snapshotObject(seq: 5, active: 1, startedAt: nowMilliseconds()))
    check(highlighted(store) == 1 && selectionReads.count == 2, "and a snapshot that agrees with it needs no question")
}

withPresser(reading: true) { store, presses, commands in
    // Safari's answer is also the anchor from then on: a snapshot older than the answer is old.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    wait(1.1)
    let before = nowMilliseconds()
    wait(0.05)
    send(store, snapshotObject(seq: 3, active: 1, startedAt: nowMilliseconds()))
    selectionReads[0].finish(.tab(position: 0))
    check(highlighted(store) == 1, "Safari moved on")
    send(store, snapshotObject(seq: 4, active: 3, startedAt: before))
    check(highlighted(store) == 1, "a snapshot started before that answer doesn't take the highlight back to the clicked tab")
    check(selectionReads.count == 1, "and needs no question")
}

withPresser(reading: true) { store, presses, commands in
    // The answer is dropped if a click has come since.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    wait(1.1)
    send(store, snapshotObject(seq: 3, active: 1, startedAt: nowMilliseconds()))
    click(store, tab: 4)
    selectionReads[0].finish(.tab(position: 0))
    check(highlighted(store) == 4, "an answer that arrives after a newer click doesn't move the highlight")
}

withPresser(reading: true) { store, presses, commands in
    // Safari can't say, and the click is long confirmed: the snapshot is believed.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    activated(store, tab: 3, seq: 2, at: nowMilliseconds())
    wait(1.1)
    send(store, snapshotObject(seq: 3, active: 1, startedAt: nowMilliseconds()))
    selectionReads[0].finish(.unknown("2 buttons for 4 tabs"))
    check(highlighted(store) == 1, "when the tab bar can't be mapped to the tabs, the snapshot is taken as before")
}

withPresser(reading: true) { store, presses, commands in
    // While the click is still waited for, a snapshot that can't be checked keeps the highlight on the clicked tab.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    send(store, snapshotObject(seq: 2, active: 1, startedAt: nowMilliseconds()))
    selectionReads[0].finish(.unknown("Safari didn't answer in time"))
    check(highlighted(store) == 3, "within the first second, a snapshot that Safari's tab bar can't settle doesn't move the highlight either")
}

withPresser(reading: true) { store, presses, commands in
    // The one-second check asks the tab bar as well as the extension, and settles the highlight from it.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    wait(1.2)
    check(snapshotRequests(commands()) == 1, "the extension is still asked for a snapshot")
    check(selectionReads.count == 1, "and so is Safari's tab bar")
    selectionReads[0].finish(.tab(position: 2))
    check(highlighted(store) == 3, "Safari is on the clicked tab: the highlight stays")
    activated(store, tab: 2, seq: 2, at: nowMilliseconds())
    check(highlighted(store) == 3 && selectionReads.count == 2, "and the click counts as confirmed: a report of another tab is then checked like any")
}

withPresser(reading: true) { store, presses, commands in
    // The press was acknowledged but Safari didn't switch (or moved on) and the starved extension says nothing.
    click(store, tab: 3)
    presses()[0].finish(.pressed(milliseconds: 4))
    wait(1.2)
    selectionReads[0].finish(.tab(position: 0))
    check(highlighted(store) == 1, "Safari is on another tab: the highlight goes back there, without waiting for the extension")
    check(activations(commands()).isEmpty, "and no command is sent")
}

withPresser(reading: true) { store, presses, commands in
    // A click on the tab the highlight is on, Safari being elsewhere, then a lost report: the next click still presses.
    send(store, snapshotObject(seq: 5, active: 3))
    click(store, tab: 1)
    presses()[0].finish(.pressed(milliseconds: 4))
    wait(1.2)
    selectionReads[0].finish(.tab(position: 2))
    check(highlighted(store) == 3, "Safari stayed on tab 3: the highlight returns to it")
    click(store, tab: 3)
    check(presses().count == 2, "and a click on tab 3 is still looked into rather than ignored")
}

// MARK: - Fixes found alongside (#21)

/// A snapshot of windows whose active tabs have these titles; `focused` is the window id Safari says has focus.
func windowsSnapshot(seq: Int, focused: Int, _ windows: [(id: Int, activeTitle: String, incognito: Bool)]) -> [String: Any] {
    ["type": "snapshot", "instance": instance, "seq": seq, "focusedWindowId": focused, "lastFocusedWindowId": focused,
     "focusChangedAt": 1.0,
     "windows": windows.map { window -> [String: Any] in
        ["id": window.id, "focused": window.id == focused, "incognito": window.incognito,
         "tabs": [["id": window.id * 100, "windowId": window.id, "index": 0, "title": window.activeTitle,
                   "url": "https://example.com/\(window.id)", "active": true, "pinned": false, "audible": false,
                   "muted": false, "loading": false] as [String: Any]]]
     }]
}

do {
    // Item 3: Safari titles a window in a profile "<profile> — <page title>".
    let (store, commands) = makeStore(active: 2)
    store.dockedWindowTitle = "Tab 2"
    check(snapshotRequests(commands()) == 0, "a window titled like its page is known")
    store.dockedWindowTitle = "Personal — Tab 2"
    check(snapshotRequests(commands()) == 0, "so is one titled with its profile's name in front")
    store.dockedWindowTitle = "Personal — Something else"
    check(snapshotRequests(commands()) == 1, "a title that fits no window still asks for a snapshot")
}

do {
    // #22 item 4: a window opened while Safari wasn't the active app. The extension's focus report still
    // names the other window, and the title the store held was the new window's before its page loaded.
    // Once the store follows the window's title, the right window is listed.
    let (store, commands) = makeStore()
    send(store, windowsSnapshot(seq: 5, focused: 1, [(1, "Test tab 29", false), (2, "Test tab 30", false)]))
    store.dockedWindowTitle = "Personal — Untitled"
    check(store.currentWindow?.window.id == 1, "with a title that fits no window, the window the extension focused is listed")
    check(snapshotRequests(commands()) == 1, "and Safari is asked for a snapshot")
    store.dockedWindowTitle = "Personal — Test tab 30"
    check(store.currentWindow?.window.id == 2, "as soon as the docked window's title is updated, its own window is listed")
}

do {
    // The same page title in two windows, in a profile window and one without: the docked window's title picks.
    let (store, _) = makeStore()
    send(store, windowsSnapshot(seq: 5, focused: 2, [(1, "Docs — Intro", false), (2, "Intro", false)]))
    check(store.currentWindow?.window.id == 2, "the focused window is shown to begin with")
    store.dockedWindowTitle = "Docs — Intro"
    check(store.currentWindow?.window.id == 1, "a page title that itself contains \" — \" matches its window exactly, not the one it ends with")
    store.dockedWindowTitle = "Personal — Docs — Intro"
    check(store.currentWindow?.window.id == 1, "with a profile name in front, the window whose title is longest and fits is the one")
    store.dockedWindowTitle = "Personal — Intro"
    check(store.currentWindow?.window.id == 2, "and \"Intro\" in that profile is the other window")
}

do {
    // A title that only ends the same way isn't a match without the separator.
    let (store, commands) = makeStore()
    send(store, windowsSnapshot(seq: 5, focused: 1, [(1, "Home", false)]))
    store.dockedWindowTitle = "My Home"
    check(snapshotRequests(commands()) == 1, "\"My Home\" is not the window titled \"Home\"")
}

do {
    // Private windows keep their rule: the page title is somewhere in the title.
    let (store, commands) = makeStore()
    send(store, windowsSnapshot(seq: 5, focused: 1, [(1, "Apple", true)]))
    store.dockedWindowTitle = "Apple, Private Browsing"
    check(snapshotRequests(commands()) == 0, "a private window's title only has to contain the page title")
}

do {
    // Item 2: the icon changes at once, and the snapshot that follows settles it.
    let (store, commands) = makeStore()
    let tab = store.tab(for: TabKey(instance: instance, tabId: 2))!
    store.setMuted(true, tab: tab, instance: instance)
    check(store.tab(for: TabKey(instance: instance, tabId: 2))?.muted == true, "muting shows the muted icon at once")
    check(commands().contains { $0["action"] as? String == "mute" && $0["muted"] as? Bool == true }, "and tells the extension")
    let muted = store.tab(for: TabKey(instance: instance, tabId: 2))!
    store.setMuted(false, tab: muted, instance: instance)
    check(store.tab(for: TabKey(instance: instance, tabId: 2))?.muted == false, "unmuting shows it at once too")
}

// MARK: - An open bookmark's tab stays under its bookmark (#25)

/// A snapshot of windows given as (window id, its tabs as (id, page)). `active` are the tabs showing
/// in their windows. It starts after any link made before it, unless `startedAt` says otherwise.
func pagesSnapshot(
    seq: Int,
    from profile: String = instance,
    focused: Int = 1,
    startedAt: Double? = nil,
    _ windows: [(id: Int, tabs: [(id: Int, url: String)])],
    active: Set<Int> = []
) -> [String: Any] {
    ["type": "snapshot", "instance": profile, "seq": seq, "focusedWindowId": focused, "lastFocusedWindowId": focused,
     "focusChangedAt": Double(seq), "startedAt": startedAt ?? nowMilliseconds() + 1,
     "windows": windows.map { window -> [String: Any] in
         ["id": window.id, "focused": window.id == focused, "incognito": false,
          "tabs": window.tabs.enumerated().map { position, tab -> [String: Any] in
              ["id": tab.id, "windowId": window.id, "index": position, "title": "Page \(tab.id)", "url": tab.url,
               "active": active.contains(tab.id), "pinned": false, "audible": false, "muted": false, "loading": false]
          }]
     }]
}

/// The tabs listed under Tabs in the window the sidebar shows.
func listedIds(_ store: TabStore, bookmarksShown: Bool = true) -> [Int] {
    guard let selection = store.currentWindow else { return [] }
    return store.tabsListed(in: selection.window, instance: selection.instance, bookmarksShown: bookmarksShown).map(\.id)
}

func creates(_ commands: [[String: Any]]) -> [[String: Any]] {
    commands.filter { $0["action"] as? String == "create" }
}

func closes(_ commands: [[String: Any]]) -> [[Int]] {
    commands.filter { $0["action"] as? String == "close" }.compactMap { $0["tabIds"] as? [Int] }
}

/// Adds a bookmark for `url` to `list` (Favorites, where #25's bookmarks went) and returns it.
func bookmark(_ store: TabStore, _ url: String, to list: BookmarkList = .favorites) -> Bookmark {
    store.addBookmark(url: URL(string: url)!, to: list)
    return store.bookmarks(in: list).last!
}

/// Opens the bookmark as a click does, and answers the extension's `create` with tab `tabId`.
func openAndCreate(_ store: TabStore, _ bookmark: Bookmark, commands: () -> [[String: Any]], tabId: Int, from profile: String = instance, inNewTab: Bool = false) {
    let before = creates(commands()).count
    store.open(bookmark, inNewTab: inNewTab)
    guard creates(commands()).count == before + 1, let requestId = creates(commands()).last?["requestId"] as? String else {
        check(false, "opening the bookmark asks Safari for a new tab")
        return
    }
    send(store, ["type": "created", "instance": profile, "requestId": requestId, "tabId": tabId])
}

let news = "https://news.example/"
let elsewhere = "https://elsewhere.example/story"

do {
    // Open a bookmark, browse away in its tab, switch to it, and close it with the −.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    check(store.openTab(for: saved) == nil, "a bookmark starts out closed")
    openAndCreate(store, saved, commands: commands, tabId: 10)
    check(creates(commands()).last?["url"] as? String == news, "opening it opens its saved page")
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (2, "https://example.com/2"), (10, news)])], active: [10]))
    check(store.openTab(for: saved)?.id == 10, "the new tab is the bookmark's")
    check(listedIds(store) == [1, 2], "a bookmark's tab isn't in the Tabs list (nor its count)")
    check(listedIds(store, bookmarksShown: false) == [1, 2, 10], "unless bookmarks are hidden: then every tab is listed")
    check(store.openTab(for: saved)?.active == true, "the bookmark's row is highlighted while its tab is active")

    send(store, pagesSnapshot(seq: 3, [(1, [(1, "https://example.com/1"), (2, "https://example.com/2"), (10, elsewhere)])], active: [1]))
    check(store.openTab(for: saved)?.id == 10, "browsing to another site in the tab doesn't unlink it")
    check(listedIds(store) == [1, 2], "and it stays out of the Tabs list")
    check(store.openTab(for: saved)?.active == false, "the row isn't highlighted while another tab is active")

    let createsBefore = creates(commands()).count
    store.open(saved)
    check(activations(commands()).last == 10, "pressing the row switches to the bookmark's tab")
    check(creates(commands()).count == createsBefore, "and opens nothing new")

    check(store.closeBookmarkTab(saved.id), "the − closes the bookmark's tab")
    check(closes(commands()).last == [10], "it asks Safari to close that tab")
    check(store.openTab(for: saved) == nil, "and the bookmark is closed again at once")
    openAndCreate(store, saved, commands: commands, tabId: 11)
    check(creates(commands()).last?["url"] as? String == news, "the next click opens the saved page fresh")
}

do {
    // A quick second click while the first one's tab is opening.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    store.open(saved)
    store.open(saved)
    check(creates(commands()).count == 1, "a second click before Safari reports the new tab doesn't open another")
    let requestId = creates(commands()).last?["requestId"] as? String ?? ""
    send(store, ["type": "created", "instance": instance, "requestId": requestId, "tabId": 10])
    store.open(saved)
    check(creates(commands()).count == 1, "nor one after Safari reports it but before a snapshot has it")
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, news)])], active: [10]))
    store.open(saved)
    check(creates(commands()).count == 1 && activations(commands()).last == 10, "once a snapshot has it, a click switches to it")
}

do {
    // A middle click does what the − does, and nothing on a closed bookmark.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    openAndCreate(store, saved, commands: commands, tabId: 10)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, elsewhere)])], active: [10]))
    check(store.closeBookmarkTab(saved.id), "a middle click on an open bookmark closes its tab")
    check(closes(commands()).last == [10] && store.openTab(for: saved) == nil, "and puts the bookmark back to closed")
    let sent = commands().count
    check(!store.closeBookmarkTab(saved.id), "a middle click on a closed bookmark does nothing")
    check(commands().count == sent, "and sends Safari nothing")
}

do {
    // Closed in Safari (⌘W, its tab bar): the tab is missing from the next snapshot.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    openAndCreate(store, saved, commands: commands, tabId: 10)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, elsewhere)])], active: [10]))
    send(store, pagesSnapshot(seq: 3, [(1, [(1, "https://example.com/1")])], active: [1]))
    check(store.openTab(for: saved) == nil, "a bookmark's tab closed in Safari puts the bookmark back to closed")
    check(store.bookmarkTabs.owners.isEmpty, "and forgets the tab")
    openAndCreate(store, saved, commands: commands, tabId: 12)
    check(creates(commands()).last?["url"] as? String == news, "the next click opens the saved page")
}

do {
    // Closed with the sidebar's own commands.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    openAndCreate(store, saved, commands: commands, tabId: 10)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, elsewhere)])], active: [10]))
    store.close([store.tab(for: TabKey(instance: instance, tabId: 10))!], instance: instance)
    check(store.openTab(for: saved) == nil, "closing a bookmark's tab from the sidebar puts the bookmark back to closed at once")
}

do {
    // Close Other Tabs and Close Tabs Below act on the Tabs list, which a bookmark's tab isn't in.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    openAndCreate(store, saved, commands: commands, tabId: 10)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, elsewhere), (2, "https://example.com/2")])], active: [1]))
    let first = store.tab(for: TabKey(instance: instance, tabId: 1))!
    store.closeTabsBelow(first, instance: instance)
    check(closes(commands()).last == [2], "Close Tabs Below closes the tabs listed below, not a bookmark's tab between them")
    send(store, pagesSnapshot(seq: 3, [(1, [(1, "https://example.com/1"), (10, elsewhere), (3, "https://example.com/3")])], active: [3]))
    store.closeOtherTabs(than: store.tab(for: TabKey(instance: instance, tabId: 3))!, instance: instance)
    check(closes(commands()).last == [1], "Close Other Tabs leaves the bookmark's tab open too")
    check(store.openTab(for: saved)?.id == 10, "and the bookmark stays open")

    let (hidden, hiddenCommands) = makeStore()
    let other = bookmark(hidden, news)
    openAndCreate(hidden, other, commands: hiddenCommands, tabId: 10)
    send(hidden, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, elsewhere)])], active: [1]))
    hidden.closeOtherTabs(than: hidden.tab(for: TabKey(instance: instance, tabId: 1))!, instance: instance, bookmarksShown: false)
    check(closes(hiddenCommands()).last == [10], "with bookmarks hidden, every tab is listed, so Close Other Tabs closes it")
    check(hidden.openTab(for: other) == nil, "and its bookmark is closed")
}

do {
    // A snapshot that was started before the new tab opened can't have it. That isn't the tab closing.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    openAndCreate(store, saved, commands: commands, tabId: 10)
    send(store, pagesSnapshot(seq: 2, startedAt: nowMilliseconds() - 500, [(1, [(1, "https://example.com/1")])], active: [1]))
    check(store.bookmarkTabs.owners[TabKey(instance: instance, tabId: 10)] == saved.id, "a snapshot started before the bookmark's tab opened doesn't close the bookmark")
    send(store, pagesSnapshot(seq: 3, [(1, [(1, "https://example.com/1"), (10, news)])], active: [10]))
    check(store.openTab(for: saved)?.id == 10, "and the next snapshot shows the tab under its bookmark")
}

do {
    // Each window has its own tab for a bookmark.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    let windows: (Int?) -> [(id: Int, tabs: [(id: Int, url: String)])] = { second in
        [(1, [(1, "https://example.com/1"), (10, news)]), (2, [(2, "https://example.com/2")] + (second.map { [($0, news)] } ?? []))]
    }
    openAndCreate(store, saved, commands: commands, tabId: 10)
    send(store, pagesSnapshot(seq: 2, focused: 1, windows(nil), active: [10, 2]))
    check(store.openTab(for: saved)?.id == 10, "the bookmark is open in the window it was opened in")
    send(store, pagesSnapshot(seq: 3, focused: 2, windows(nil), active: [10, 2]))
    check(store.openTab(for: saved) == nil, "and closed in another window")
    check(listedIds(store) == [2], "where its tab in the first window isn't listed either")
    openAndCreate(store, saved, commands: commands, tabId: 20)
    check(creates(commands()).last?["windowId"] as? Int == 2, "a click there opens a tab in that window")
    send(store, pagesSnapshot(seq: 4, focused: 2, windows(20), active: [10, 20]))
    check(store.openTab(for: saved)?.id == 20, "which is the bookmark's tab in that window")
    check(store.closeBookmarkTab(saved.id) && closes(commands()).last == [20], "the − closes the tab of the window it's shown in")
    send(store, pagesSnapshot(seq: 5, focused: 1, windows(nil), active: [10, 2]))
    check(store.openTab(for: saved)?.id == 10, "and leaves the first window's tab with the bookmark")
}

do {
    // A bookmark's tab moved into a window where the bookmark already has one.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    openAndCreate(store, saved, commands: commands, tabId: 10)
    send(store, pagesSnapshot(seq: 2, focused: 2, [(1, [(1, "https://example.com/1"), (10, news)]), (2, [(2, "https://example.com/2")])], active: [10, 2]))
    openAndCreate(store, saved, commands: commands, tabId: 20)
    send(store, pagesSnapshot(seq: 3, focused: 1, [(1, [(1, "https://example.com/1"), (10, news)]), (2, [(2, "https://example.com/2"), (20, elsewhere)])], active: [10, 20]))
    send(store, pagesSnapshot(seq: 4, focused: 1, [(1, [(1, "https://example.com/1"), (10, news), (20, elsewhere)]), (2, [(2, "https://example.com/2")])], active: [20, 2]))
    check(store.openTab(for: saved)?.id == 20, "of two tabs of one bookmark in a window, the one showing stays the bookmark's")
    check(listedIds(store) == [1, 10], "and the other goes back under Tabs")
}

do {
    // An ordinary tab that happens to be on a bookmark's page.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (5, "https://news.example")])], active: [1]))
    check(store.openTab(for: saved) == nil, "an ordinary tab on a bookmark's page doesn't make the bookmark open")
    check(listedIds(store) == [1, 5], "and stays under Tabs")
    let createsBefore = creates(commands()).count
    store.open(saved)
    check(creates(commands()).count == createsBefore, "clicking the bookmark doesn't open a second copy")
    check(store.openTab(for: saved)?.id == 5 && activations(commands()).last == 5, "it switches to that tab, which becomes the bookmark's")
    check(listedIds(store) == [1], "and moves up out of Tabs")
}

do {
    // Open in New Tab on a bookmark that's open in this window gives an ordinary tab.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    openAndCreate(store, saved, commands: commands, tabId: 10)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, elsewhere)])], active: [10]))
    openAndCreate(store, saved, commands: commands, tabId: 11, inNewTab: true)
    send(store, pagesSnapshot(seq: 3, [(1, [(1, "https://example.com/1"), (10, elsewhere), (11, news)])], active: [11]))
    check(store.openTab(for: saved)?.id == 10, "Open in New Tab on an open bookmark leaves its tab as it is")
    check(listedIds(store) == [1, 11], "and the new tab is an ordinary one")
}

do {
    // Dragging a tab onto Bookmarks, Replace with Current Page, and Remove Bookmark.
    let (store, _) = makeStore()
    store.addBookmark(from: store.tab(for: TabKey(instance: instance, tabId: 3))!, instance: instance, to: .favorites, at: 0)
    let dragged = store.favorites[0]
    check(dragged.url == "https://example.com/3", "a tab dragged onto Bookmarks makes a bookmark of its page")
    check(store.openTab(for: dragged)?.id == 3, "which owns the tab")
    check(listedIds(store) == [1, 2, 4], "so the tab moves up out of Tabs")

    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (2, "https://example.com/2"), (3, elsewhere), (4, "https://example.com/4")])], active: [3]))
    store.replaceBookmarkWithCurrentPage(dragged)
    check(store.favorites[0].url == elsewhere, "Replace with Current Page saves the tab's current page as the bookmark's")
    check(store.openTab(for: store.favorites[0])?.id == 3, "and the tab stays the bookmark's")

    store.removeBookmark(store.favorites[0])
    check(store.bookmarkTabs.owners.isEmpty, "removing the bookmark lets go of its tab")
    check(listedIds(store) == [1, 2, 3, 4], "which goes back under Tabs, still open")
}

do {
    // Reordering the Tabs list puts a tab among the listed ones, wherever bookmarks' tabs are.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    openAndCreate(store, saved, commands: commands, tabId: 10)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, elsewhere), (2, "https://example.com/2"), (3, "https://example.com/3")])], active: [1]))
    let moves = { commands().filter { $0["action"] as? String == "move" }.compactMap { $0["index"] as? Int } }
    store.moveTab(store.tab(for: TabKey(instance: instance, tabId: 3))!, instance: instance, toListedSlot: 1)
    check(moves().last == 2, "a tab dropped between two listed tabs goes just before the second, past the bookmark's tab")
    check(listedIds(store) == [1, 3, 2], "and shows there")
    store.moveTab(store.tab(for: TabKey(instance: instance, tabId: 1))!, instance: instance, toListedSlot: 2)
    check(moves().last == 3, "one dropped at the end goes after the last listed tab")
    check(listedIds(store) == [3, 2, 1], "and shows there")
}

do {
    // Links survive Side Tabs restarting, even for a profile that reports later than another.
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    let store = TabStore(stateURL: url)
    var sent: [[String: Any]] = []
    store.sendCommand = { sent.append($0) }
    let other = "other-profile"
    send(store, pagesSnapshot(seq: 1, [(1, [(1, "https://example.com/1")])], active: [1]))
    let saved = bookmark(store, news)
    let docs = bookmark(store, "https://docs.example/")
    openAndCreate(store, saved, commands: { sent }, tabId: 10)
    openAndCreate(store, docs, commands: { sent }, tabId: 12)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, elsewhere), (12, "https://docs.example/")])], active: [10]))
    send(store, pagesSnapshot(seq: 3, from: other, focused: 5, [(5, [(50, "https://example.com/5")])], active: [50]))
    openAndCreate(store, saved, commands: { sent }, tabId: 51, from: other)
    send(store, pagesSnapshot(seq: 4, from: other, focused: 5, [(5, [(50, "https://example.com/5"), (51, elsewhere)])], active: [51]))
    check(store.bookmarkTabs.owners.count == 3, "three tabs belong to bookmarks before the restart")
    store.save()

    let reloaded = TabStore(stateURL: url)
    check(reloaded.bookmarkTabs.owners.count == 3, "the links are read back from state.json")
    // Safari kept running. Meanwhile the docs tab closed, and a tab went to the docs page.
    send(reloaded, pagesSnapshot(seq: 5, [(1, [(1, "https://example.com/1"), (10, elsewhere), (13, "https://docs.example/")])], active: [10]))
    check(reloaded.openTab(for: saved)?.id == 10, "a bookmark's tab is still its own after Side Tabs restarts, though it browsed away")
    check(reloaded.openTab(for: docs) == nil, "one that closed meanwhile is closed")
    check(listedIds(reloaded) == [1, 13], "and a tab on a bookmark's page that wasn't its tab stays under Tabs")
    check(reloaded.bookmarkTabs.owners[TabKey(instance: other, tabId: 51)] == saved.id, "a profile that hasn't reported yet keeps its links")
    send(reloaded, pagesSnapshot(seq: 6, from: other, focused: 5, [(5, [(50, "https://example.com/5"), (51, elsewhere)])], active: [51]))
    check(reloaded.openTab(for: saved)?.id == 51, "and has them when it does")
}

do {
    // Safari restarts: tab ids change, and only a restored tab still on the saved page goes back to its bookmark.
    let (store, commands) = makeStore()
    let saved = bookmark(store, news)
    let docs = bookmark(store, "https://docs.example/")
    openAndCreate(store, saved, commands: commands, tabId: 10)
    openAndCreate(store, docs, commands: commands, tabId: 11)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, news), (11, elsewhere)])], active: [1]))
    store.safariDidTerminate()
    send(store, pagesSnapshot(seq: 1, from: "restarted", focused: 7, [(7, [(30, "https://example.com/1"), (31, news), (32, elsewhere)])], active: [30]))
    check(store.openTab(for: saved)?.id == 31, "after Safari restarts, a restored tab still on the bookmark's page goes back to it")
    check(store.openTab(for: docs) == nil, "one that had browsed away comes back under Tabs")
    check(listedIds(store) == [30, 32], "so the Tabs list has it")
}

do {
    // Safari restarted while Side Tabs wasn't running.
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    let store = TabStore(stateURL: url)
    var sent: [[String: Any]] = []
    store.sendCommand = { sent.append($0) }
    send(store, pagesSnapshot(seq: 1, [(1, [(1, "https://example.com/1")])], active: [1]))
    let saved = bookmark(store, news)
    openAndCreate(store, saved, commands: { sent }, tabId: 10)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, news)])], active: [10]))
    store.save()

    let relaunched = TabStore(stateURL: url)
    send(relaunched, pagesSnapshot(seq: 1, from: "relaunched", focused: 3, [(3, [(40, "https://example.com/1"), (41, news)])], active: [41]))
    check(relaunched.openTab(for: saved)?.id == 41, "a tab Safari restored while Side Tabs wasn't running goes back to its bookmark")
    check(relaunched.bookmarkTabs.owners.count == 1, "and the old tab id is forgotten")
}

do {
    // A state.json saved before bookmarks' tabs were saved still loads.
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    try! FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
    let old = #"{"bookmarks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","url":"https://old.example/"}],"names":[],"orphanNames":{}}"#
    try! old.write(to: url, atomically: true, encoding: .utf8)
    let store = TabStore(stateURL: url)
    check(store.favorites.map(\.title) == ["Old"], "an older state.json without bookmarks' tabs still loads its bookmarks")
}

// MARK: - Favorites, shared by every profile, and a Pinned list for each (#34)

// Each Safari profile runs its own copy of the extension. Safari sends each copy's messages with the
// profile's UUID, except the default profile's, whose copy also reports private windows.
let defaultCopy = "copy-default"
let workCopy = "copy-work"
let workUUID = "8B1A3C55-1D2E-4F60-8A7B-9C0D1E2F3A4B"
let work = ProfileKey(rawValue: workUUID)

typealias PageTabs = [(id: Int, url: String)]

/// A snapshot from one copy of the extension. `profile` is the UUID Safari sends with it (none for the
/// default profile). Each window is (id, whether it's private, its tabs as (id, page)).
func spaceSnapshot(
    seq: Int,
    from copy: String,
    profile: String? = nil,
    focused: Int,
    lastFocused: Int? = nil,
    focusChangedAt: Double,
    _ windows: [(id: Int, incognito: Bool, tabs: PageTabs)],
    active: Set<Int>
) -> [String: Any] {
    var object: [String: Any] = [
        "type": "snapshot", "instance": copy, "seq": seq, "focusedWindowId": focused,
        "lastFocusedWindowId": lastFocused ?? focused, "focusChangedAt": focusChangedAt,
        "startedAt": nowMilliseconds() + 1,
        "windows": windows.map { window -> [String: Any] in
            ["id": window.id, "focused": window.id == focused, "incognito": window.incognito,
             "tabs": window.tabs.enumerated().map { position, tab -> [String: Any] in
                 ["id": tab.id, "windowId": window.id, "index": position, "title": "Page \(tab.id)", "url": tab.url,
                  "active": active.contains(tab.id), "pinned": false, "audible": false, "muted": false, "loading": false]
             }]
        },
    ]
    if let profile { object["profile"] = profile }
    return object
}

/// Safari with two profiles. The default profile's copy has window 1 (tabs 1 and 2) and private
/// window 3 (tab 30); the Work profile's copy has window 5 (tabs 50 and 51).
final class Spaces {
    enum Window { case personal, privateBrowsing, work }

    let store: TabStore
    private(set) var commands: [[String: Any]] = []
    var personalTabs: PageTabs = [(1, "https://example.com/1"), (2, "https://example.com/2")]
    var privateTabs: PageTabs = [(30, "https://example.com/30")]
    var workTabs: PageTabs = [(50, "https://example.com/50"), (51, "https://example.com/51")]
    /// The tab showing in each window, by window id.
    var active: [Int: Int] = [1: 1, 3: 30, 5: 50]
    private var seq = 0
    private var focusClock = 10.0
    private(set) var front = Window.personal

    /// A store that keeps its state at `stateURL`, which has heard from both copies with the default
    /// profile's window in front. With `other`, Safari has the tabs that one had.
    init(stateURL: URL? = nil, tabsOf other: Spaces? = nil) {
        storeCount += 1
        store = TabStore(stateURL: stateURL ?? stateFolder.appending(path: "state-\(storeCount).json"))
        if let other {
            personalTabs = other.personalTabs
            privateTabs = other.privateTabs
            workTabs = other.workTabs
            active = other.active
        }
        store.sendCommand = { [unowned self] in self.commands.append($0) }
        show(.personal)
    }

    /// Both copies report, with `window` in front: its copy changed focus last.
    func show(_ window: Window) {
        front = window
        seq += 1
        focusClock += 1
        let shown = Set(active.values)
        let defaultInFront = window != .work
        send(store, spaceSnapshot(
            seq: seq, from: defaultCopy, focused: defaultInFront ? (window == .personal ? 1 : 3) : -1, lastFocused: window == .privateBrowsing ? 3 : 1,
            focusChangedAt: defaultInFront ? focusClock : focusClock - 0.5,
            [(1, false, personalTabs), (3, true, privateTabs)], active: shown
        ))
        send(store, spaceSnapshot(
            seq: seq, from: workCopy, profile: workUUID, focused: defaultInFront ? -1 : 5, lastFocused: 5,
            focusChangedAt: defaultInFront ? focusClock - 0.5 : focusClock,
            [(5, false, workTabs)], active: shown
        ))
    }

    /// Opens the bookmark as a click does, answers the extension's `create` with tab `tabId`, and puts
    /// that tab in the window it was asked for, showing. Says which copy and window it was asked of.
    @discardableResult
    func openAndCreate(_ bookmark: Bookmark, tabId: Int, inNewTab: Bool = false, line: Int = #line) -> (copy: String, windowId: Int)? {
        let before = creates(commands).count
        store.open(bookmark, inNewTab: inNewTab)
        guard creates(commands).count == before + 1, let command = creates(commands).last,
              let requestId = command["requestId"] as? String, let copy = command["instance"] as? String,
              let windowId = command["windowId"] as? Int else {
            check(false, "opening the bookmark asks Safari for a new tab", line: line)
            return nil
        }
        send(store, ["type": "created", "instance": copy, "requestId": requestId, "tabId": tabId])
        switch windowId {
        case 1: personalTabs.append((tabId, bookmark.url))
        case 3: privateTabs.append((tabId, bookmark.url))
        case 5: workTabs.append((tabId, bookmark.url))
        default: check(false, "the tab opens in one of the windows", line: line)
        }
        active[windowId] = tabId
        show(front)
        return (copy, windowId)
    }

    func key(_ tabId: Int) -> TabKey {
        TabKey(instance: workTabs.contains { $0.id == tabId } ? workCopy : defaultCopy, tabId: tabId)
    }

    func tab(_ tabId: Int) -> BrowserTab {
        store.tab(for: key(tabId))!
    }
}

do {
    // Each profile has its own Pinned list, which follows the window in front; a private window has none.
    let spaces = Spaces()
    let store = spaces.store
    check(store.currentWindowProfile == .defaultProfile, "a window of the copy that sends no profile is the default profile's")
    check(store.currentPinnedList == .pinned(.defaultProfile), "and the sidebar shows the default profile's Pinned list")
    store.addBookmarkForCurrentTab()
    check(store.bookmarks(in: .pinned(.defaultProfile)).map(\.url) == ["https://example.com/1"], "Add Bookmark pins the current tab in the profile's Pinned list")
    check(store.favorites.isEmpty, "not in Favorites")
    check(store.bookmarks(in: .pinned(.defaultProfile)).first.flatMap(store.openTab(for:))?.id == 1 && listedIds(store) == [2],
          "the pinned item owns the tab, which leaves Tabs")

    spaces.show(.work)
    check(store.currentWindowProfile == work, "a window of another copy is the profile whose UUID Safari sends with it")
    check(store.currentPinnedList == .pinned(work), "switching to it swaps the Pinned list at once")
    check(store.bookmarks(in: .pinned(work)).isEmpty, "a profile's list starts empty")
    store.addBookmarkForCurrentTab()
    check(store.bookmarks(in: .pinned(work)).map(\.url) == ["https://example.com/50"], "Add Bookmark there pins to that profile's own list")
    check(store.bookmarks(in: .pinned(.defaultProfile)).map(\.url) == ["https://example.com/1"], "and leaves the other profile's list alone")

    spaces.show(.privateBrowsing)
    check(store.currentWindowProfile == nil, "a private window belongs to no profile, though the default profile's copy reports it")
    check(store.currentPinnedList == nil, "so it has no Pinned list")
    store.addBookmarkForCurrentTab()
    check(store.favorites.map(\.url) == ["https://example.com/30"], "Add Bookmark in a private window adds to Favorites")
    check(store.favorites.first.flatMap(store.openTab(for:))?.id == 30 && listedIds(store).isEmpty, "with the tab as the favorite's, out of Tabs")
    check(store.bookmarks(in: .pinned(.defaultProfile)).count == 1, "the default profile's list doesn't get it")

    spaces.show(.personal)
    check(store.currentPinnedList == .pinned(.defaultProfile), "back in the default profile's window, its own list shows again")
    check(listedIds(store) == [2], "with its pinned tab still out of Tabs")
    check(store.favorites.first.flatMap(store.openTab(for:)) == nil, "the favorite shows here too, closed in this window")

    store.dockedWindowTitle = "Work — Page 50"
    check(store.currentPinnedList == .pinned(work), "the list follows the window the sidebar is docked to, as soon as its title says which")
}

do {
    // #25's rules hold for favorites and pinned items alike.
    for list in [BookmarkList.favorites, .pinned(.defaultProfile)] {
        let spaces = Spaces()
        let store = spaces.store
        let name = list == .favorites ? "a favorite" : "a pinned item"
        let saved = bookmark(store, news, to: list)
        check(store.pressBookmark(saved, command: false) && creates(spaces.commands).isEmpty,
              "pressing \(name) that's closed waits for the button to go up, so a drag doesn't open it")
        spaces.openAndCreate(saved, tabId: 10)
        check(store.openTab(for: saved)?.id == 10, "\(name), opened, owns the new tab")
        check(listedIds(store) == [1, 2], "which isn't listed under Tabs")
        check(store.openTab(for: saved)?.active == true, "and is highlighted while that tab is active")

        spaces.active[1] = 1
        spaces.personalTabs[2].url = elsewhere
        spaces.show(.personal)
        check(store.openTab(for: saved)?.id == 10, "browsing elsewhere in its tab keeps it \(name)'s")
        check(!store.pressBookmark(saved, command: false) && activations(spaces.commands).last == 10,
              "pressing \(name) that's open switches to its tab on mouse-down")
        let createsBefore = creates(spaces.commands).count
        check(store.pressBookmark(saved, command: true) && creates(spaces.commands).count == createsBefore,
              "with ⌘ the press waits for the button to go up")
        spaces.openAndCreate(saved, tabId: 11, inNewTab: true)
        check(store.openTab(for: saved)?.id == 10 && listedIds(store) == [1, 2, 11], "and ⌘-click opens an ordinary new tab")

        check(store.closeBookmarkTab(saved.id) && closes(spaces.commands).last == [10],
              "the − (and a middle click, and Close Tab) closes \(name)'s tab")
        check(store.openTab(for: saved) == nil, "and puts it back to closed at once")
        let sent = spaces.commands.count
        check(!store.closeBookmarkTab(saved.id) && spaces.commands.count == sent, "a middle click on \(name) that's closed does nothing")
    }
}

do {
    // A favorite opens in the profile of the window it's clicked in.
    let spaces = Spaces()
    let store = spaces.store
    let saved = bookmark(store, news)
    spaces.openAndCreate(saved, tabId: 10)
    spaces.show(.work)
    check(store.openTab(for: saved) == nil, "a favorite open in one profile's window is closed in another profile's")
    let opened = spaces.openAndCreate(saved, tabId: 52)
    check(opened?.copy == workCopy && opened?.windowId == 5, "clicking it there opens its page in that window, through that profile's copy")
    check(store.openTab(for: saved)?.id == 52 && listedIds(store) == [50, 51], "and the new tab is the favorite's there")
    spaces.show(.privateBrowsing)
    let privately = spaces.openAndCreate(saved, tabId: 31)
    check(privately?.copy == defaultCopy && privately?.windowId == 3, "in a private window it opens in that private window")
    check(store.openTab(for: saved)?.id == 31, "where it owns its tab too")
    check(store.bookmarkTabKeys == [spaces.key(10), spaces.key(52), spaces.key(31)], "one tab in each window, all kept open by cleanup")
}

do {
    // Dragging a tab onto Favorites or Pinned.
    let spaces = Spaces()
    let store = spaces.store
    store.addBookmark(from: spaces.tab(2), instance: defaultCopy, to: .pinned(.defaultProfile), at: 0)
    check(store.bookmarks(in: .pinned(.defaultProfile)).first?.url == "https://example.com/2", "a tab dropped on Pinned becomes a pinned item")
    check(store.bookmarks(in: .pinned(.defaultProfile)).first.flatMap(store.openTab(for:))?.id == 2 && listedIds(store) == [1], "that owns the tab")
    store.addBookmark(from: spaces.tab(1), instance: defaultCopy, to: .favorites, at: 0)
    check(store.favorites.first?.url == "https://example.com/1" && store.favorites.first.flatMap(store.openTab(for:))?.id == 1,
          "a tab dropped on Favorites becomes a favorite that owns the tab")
    check(listedIds(store).isEmpty, "so both left Tabs")
}

do {
    // Moving between the lists, and reordering.
    let spaces = Spaces()
    let store = spaces.store
    let saved = bookmark(store, news)
    let docs = bookmark(store, "https://docs.example/")
    spaces.openAndCreate(saved, tabId: 10)
    spaces.show(.work)
    spaces.openAndCreate(saved, tabId: 52)
    spaces.show(.privateBrowsing)
    spaces.openAndCreate(saved, tabId: 31)
    spaces.show(.personal)

    store.moveBookmark(saved.id, to: .pinned(.defaultProfile), at: 0)
    check(store.favorites.map(\.id) == [docs.id] && store.bookmarks(in: .pinned(.defaultProfile)).map(\.id) == [saved.id],
          "Move to Pinned takes a favorite out of Favorites into the profile's Pinned list")
    check(store.openTab(for: saved)?.id == 10 && listedIds(store) == [1, 2], "it keeps its tab in that profile's window")
    check(store.bookmarkTabKeys == [spaces.key(10)], "but lets go of its tabs in windows that don't show that list")
    spaces.show(.work)
    check(listedIds(store) == [50, 51, 52], "so its tab in another profile's window is back under Tabs there")
    spaces.show(.privateBrowsing)
    check(listedIds(store) == [30, 31], "and so is its tab in a private window")

    spaces.show(.personal)
    store.moveBookmark(saved.id, to: .favorites, at: 1)
    check(store.favorites.map(\.id) == [docs.id, saved.id], "Move to Favorites, or a drop there, puts it where it's dropped")
    check(store.bookmarks(in: .pinned(.defaultProfile)).isEmpty, "and out of Pinned")
    check(store.openTab(for: saved)?.id == 10, "keeping its tab")
    spaces.show(.work)
    let workWindow = store.currentWindow!
    check(store.bookmarkIds(shownIn: workWindow.window, instance: workWindow.instance).contains(saved.id), "and it's shared now: every profile shows it")

    store.moveBookmark(saved.id, to: .favorites, at: 0)
    check(store.favorites.map(\.id) == [saved.id, docs.id], "favorites reorder by dragging")
    store.moveBookmark(docs.id, to: .pinned(work), at: 5)
    store.moveBookmark(saved.id, to: .pinned(work), at: 0)
    check(store.bookmarks(in: .pinned(work)).map(\.id) == [saved.id, docs.id], "a drop past the end of a list goes at its end")
    store.moveBookmark(saved.id, to: .pinned(work), at: 1)
    check(store.bookmarks(in: .pinned(work)).map(\.id) == [docs.id, saved.id], "and pinned items reorder too")
    let ids = store.bookmarkLists.all.map(\.id)
    check(Set(ids).count == ids.count && ids.count == 2, "a bookmark is in one list only, with its own id")
}

do {
    // Everything survives saving and loading.
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    let spaces = Spaces(stateURL: url)
    let store = spaces.store
    let favorite = bookmark(store, news)
    let here = bookmark(store, "https://docs.example/", to: .pinned(.defaultProfile))
    let there = bookmark(store, "https://work.example/", to: .pinned(work))
    spaces.openAndCreate(here, tabId: 10)
    spaces.show(.work)
    spaces.openAndCreate(there, tabId: 52)
    spaces.openAndCreate(favorite, tabId: 53)
    store.beginRename(.bookmark(there.id))
    store.commitRename("Renamed")
    check(store.bookmarks(in: .pinned(work)).first?.title == "Renamed", "a pinned item can be renamed")
    store.save()

    let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    let urls = { (list: Any?) in (list as? [[String: Any]])?.compactMap { $0["url"] as? String } ?? [] }
    check(urls(json["bookmarks"]) == [news], "state.json keeps the favorites under bookmarks, as before")
    let pinned = json["pinned"] as? [String: Any] ?? [:]
    check(urls(pinned["default"]) == ["https://docs.example/"] && urls(pinned[workUUID]) == ["https://work.example/"],
          "and each profile's Pinned list under the profile's key")

    let reloaded = Spaces(stateURL: url, tabsOf: spaces)
    check(reloaded.store.bookmarkLists == store.bookmarkLists, "the lists load back as they were, with their ids, names and order")
    check(reloaded.store.bookmarkTabs.owners == store.bookmarkTabs.owners, "and so do their tabs")
    check(reloaded.store.currentPinnedList == .pinned(.defaultProfile) && reloaded.store.openTab(for: here)?.id == 10,
          "the default profile's window shows its own list, with its tab")
    reloaded.show(.work)
    check(reloaded.store.bookmarks(in: reloaded.store.currentPinnedList!).map(\.title) == ["Renamed"], "and Work's window shows Work's")
    check(reloaded.store.openTab(for: there)?.id == 52 && reloaded.store.openTab(for: favorite)?.id == 53 && listedIds(reloaded.store) == [50, 51],
          "with their tabs still theirs")
}

do {
    // An old state.json: its bookmarks are the favorites, and stay under `bookmarks` when it's saved again.
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    try! FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
    let old = #"{"bookmarks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","url":"https://old.example/"},{"id":"7A9619FF-8B86-D011-B42D-00C04FC964FF","title":"Older","url":"https://older.example/"}],"names":[],"orphanNames":{},"bookmarkTabs":[{"instance":"copy-default","tabId":2,"bookmark":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}],"instances":["copy-default"]}"#
    try! old.write(to: url, atomically: true, encoding: .utf8)
    let spaces = Spaces(stateURL: url)
    let store = spaces.store
    check(store.favorites.map(\.title) == ["Old", "Older"], "an old state.json's bookmarks load as the favorites, in the same order")
    check(store.bookmarkLists.pinned.isEmpty, "and every profile's Pinned list starts empty")
    check(store.favorites.first.flatMap(store.openTab(for:))?.id == 2 && listedIds(store) == [1], "a bookmark's tab stays its own as a favorite")
    store.save()
    let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    check(((json["bookmarks"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String } == ["6F9619FF-8B86-D011-B42D-00C04FC964FF", "7A9619FF-8B86-D011-B42D-00C04FC964FF"],
          "saved again, they're still under bookmarks with their ids")
}

do {
    // Ids stay unique across the lists, even in a state.json edited by hand.
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    let edited = #"{"bookmarks":[{"id":"\#(id)","title":"A","url":"https://a.example/"}],"pinned":{"default":[{"id":"\#(id)","title":"B","url":"https://b.example/"}]},"names":[],"orphanNames":{}}"#
    try! edited.write(to: url, atomically: true, encoding: .utf8)
    let store = TabStore(stateURL: url)
    let ids = store.bookmarkLists.all.map(\.id)
    check(ids.count == 2 && Set(ids).count == 2, "a repeated id gets a new one, so each bookmark keeps its own")
    check(store.favorites.first?.id.uuidString == id, "the favorite keeps the id it had")
}

do {
    // After Safari restarts, a pinned item only gets back a tab of its own profile.
    let spaces = Spaces()
    let store = spaces.store
    let pinned = bookmark(store, news, to: .pinned(work))
    spaces.show(.work)
    spaces.openAndCreate(pinned, tabId: 52)
    store.safariDidTerminate()
    send(store, spaceSnapshot(seq: 1, from: "restarted-default", focused: 7, focusChangedAt: 100, [(7, false, [(70, news)])], active: [70]))
    check(store.bookmarkTabs.owners.isEmpty, "a restored tab of another profile on the pinned item's page doesn't become its tab")
    check(listedIds(store) == [70], "and stays under Tabs")
    send(store, spaceSnapshot(seq: 1, from: "restarted-work", profile: workUUID, focused: 8, focusChangedAt: 101, [(8, false, [(80, news)])], active: [80]))
    check(store.bookmarkTabs.owners == [TabKey(instance: "restarted-work", tabId: 80): pinned.id], "one of its own profile does")
}

try? FileManager.default.removeItem(at: stateFolder)

if failures == 0 {
    print("store checks passed")
} else {
    print("\(failures) store check(s) failed")
    exit(1)
}
