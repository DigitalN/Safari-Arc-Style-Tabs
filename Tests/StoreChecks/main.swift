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

try? FileManager.default.removeItem(at: stateFolder)

if failures == 0 {
    print("store checks passed")
} else {
    print("\(failures) store check(s) failed")
    exit(1)
}
