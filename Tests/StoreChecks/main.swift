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
    other["profile"] = "OTHER-PROFILE"
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

// MARK: - Focus moving to another profile's window (#36)

/// A snapshot from extension copy `copy` (of profile `profile`; the default profile's copy sends none) with one
/// window, whose active tab is titled `title`. `focused` says whether that window has focus, as of `at`
/// (`focusChangedAt`). A copy that loses focus to another profile's window reports none.
func copySnapshot(_ copy: String, profile: String?, seq: Int, window: Int, title: String, focused: Bool, at: Double) -> [String: Any] {
    var object: [String: Any] = [
        "type": "snapshot", "instance": copy, "seq": seq,
        "focusedWindowId": focused ? window : -1, "lastFocusedWindowId": window, "focusChangedAt": at,
        "windows": [["id": window, "focused": focused, "incognito": false,
                     "tabs": [["id": window * 100, "windowId": window, "index": 0, "title": title,
                               "url": "https://example.com/\(window)", "active": true, "pinned": false, "audible": false,
                               "muted": false, "loading": false] as [String: Any]]]],
    ]
    if let profile { object["profile"] = profile }
    return object
}

let workProfile = "WWWWWWWW-0000-0000-0000-000000000000"

/// A store with no extension copy yet (makeStore's has one, whose window has focus).
func storeWithoutCopies() -> TabStore {
    storeCount += 1
    return TabStore(stateURL: stateFolder.appending(path: "state-\(storeCount).json"))
}

do {
    // A (the default profile's copy) had focus; it moves to B's window (Work). B reports the gain, then A
    // reports the loss, with a newer time.
    let store = storeWithoutCopies()
    send(store, copySnapshot("A", profile: nil, seq: 1, window: 1, title: "Mail", focused: true, at: 100))
    send(store, copySnapshot("B", profile: workProfile, seq: 1, window: 7, title: "Docs", focused: false, at: 50))
    store.dockedWindowTitle = nil
    check(store.currentWindow?.instance == "A", "A's window has focus to begin with")
    send(store, copySnapshot("B", profile: workProfile, seq: 2, window: 7, title: "Docs", focused: true, at: 200))
    send(store, copySnapshot("A", profile: nil, seq: 2, window: 1, title: "Mail", focused: false, at: 201))
    check(store.currentWindow?.instance == "B", "A losing focus after B gained it: B's window is shown")
}

do {
    // The same reports in the other order: A's loss arrives first, then B's gain.
    let store = storeWithoutCopies()
    send(store, copySnapshot("A", profile: nil, seq: 1, window: 1, title: "Mail", focused: true, at: 100))
    send(store, copySnapshot("B", profile: workProfile, seq: 1, window: 7, title: "Docs", focused: false, at: 50))
    store.dockedWindowTitle = nil
    send(store, copySnapshot("A", profile: nil, seq: 2, window: 1, title: "Mail", focused: false, at: 201))
    send(store, copySnapshot("B", profile: workProfile, seq: 2, window: 7, title: "Docs", focused: true, at: 200))
    check(store.currentWindow?.instance == "B", "B gaining focus after A reported losing it: B's window is shown")

    // Both still claim focus (A's loss not in yet): the newer focus change wins.
    send(store, copySnapshot("A", profile: nil, seq: 3, window: 1, title: "Mail", focused: true, at: 300))
    check(store.currentWindow?.instance == "A", "of two copies with a focused window, the newer focus change")
    // Safari in the background: no copy has a focused window, and the one that lost focus last decides, as before.
    send(store, copySnapshot("A", profile: nil, seq: 4, window: 1, title: "Mail", focused: false, at: 400))
    send(store, copySnapshot("B", profile: workProfile, seq: 3, window: 7, title: "Docs", focused: false, at: 350))
    check(store.currentWindow?.instance == "A", "no copy with a focused window: the newest focus change's last focused window")
}

do {
    // B's gain hasn't arrived, but the docked window's toolbar says it's in Work: Work's copy is used.
    let store = storeWithoutCopies()
    send(store, copySnapshot("A", profile: nil, seq: 1, window: 1, title: "Mail", focused: false, at: 201))
    send(store, copySnapshot("B", profile: workProfile, seq: 1, window: 7, title: "Docs", focused: false, at: 50))
    store.dockedWindowTitle = nil
    check(store.currentWindow?.instance == "A", "without the docked window's profile, A (the newest report) is shown")
    store.dockedWindowProfile = workProfile
    check(store.currentWindow?.instance == "B", "with it, Work's copy is shown")
    send(store, copySnapshot("A", profile: nil, seq: 2, window: 1, title: "Mail", focused: true, at: 300))
    check(store.currentWindow?.instance == "B", "even while A still claims focus")
    store.dockedWindowProfile = "default"
    check(store.currentWindow?.instance == "A", "the default profile's copy is the one that sends no profile")
    store.dockedWindowProfile = "XXXXXXXX-0000-0000-0000-000000000000"
    check(store.currentWindow?.instance == "A", "a profile with no copy (Side Tabs off there): the focus reports decide")
    store.dockedWindowProfile = nil
    check(store.currentWindow?.instance == "A", "and in a private window, too")
}

do {
    // The docked window's title fits another profile's window: once the docked window's profile is known, only
    // its copy's windows can be the docked one.
    let store = storeWithoutCopies()
    send(store, copySnapshot("A", profile: nil, seq: 1, window: 1, title: "Google", focused: true, at: 300))
    send(store, copySnapshot("B", profile: workProfile, seq: 1, window: 7, title: "Mail", focused: false, at: 200))
    store.dockedWindowTitle = "Work — Google"
    check(store.currentWindow?.instance == "A", "without the profile, the title picks A's Google window")
    store.dockedWindowProfile = workProfile
    check(store.currentWindow?.instance == "B", "with it, A's window on the same page isn't taken")

    // Two profiles named alike, on the same page: the title fits both, the docked window's profile decides.
    send(store, copySnapshot("B", profile: workProfile, seq: 2, window: 7, title: "Google", focused: false, at: 200))
    store.dockedWindowTitle = "Personal — Google"
    check(store.currentWindow?.instance == "B", "two windows on the same page: the docked profile's")
    store.dockedWindowProfile = "default"
    check(store.currentWindow?.instance == "A", "and the other way round")
}

// MARK: - A docked window its profile's copy can't see (#41)

/// A snapshot from copy `copy` with these windows, each with tabs titled as given (the first active unless
/// `active` says otherwise). `focused` is the focused window's id, or -1.
func windowsOf(_ copy: String, profile: String?, seq: Int, focused: Int = -1, at: Double = 100,
               _ windows: [(id: Int, tabs: [String], incognito: Bool)]) -> [String: Any] {
    var object: [String: Any] = [
        "type": "snapshot", "instance": copy, "seq": seq,
        "focusedWindowId": focused, "lastFocusedWindowId": windows.first?.id ?? -1, "focusChangedAt": at,
        "windows": windows.map { window -> [String: Any] in
            ["id": window.id, "focused": window.id == focused, "incognito": window.incognito,
             "tabs": window.tabs.enumerated().map { index, title -> [String: Any] in
                ["id": window.id * 100 + index, "windowId": window.id, "index": index, "title": title,
                 "url": "https://example.com/\(window.id)/\(index)", "active": index == 0, "pinned": false,
                 "audible": false, "muted": false, "loading": false]
             }]
        },
    ]
    if let profile { object["profile"] = profile }
    return object
}

/// A store docked to a Work window titled `title`, settled, with the default profile's copy (A) showing
/// its own focused window.
func dockedToWork(_ title: String, likeWindows: Int? = 1) -> (TabStore, sent: () -> [[String: Any]]) {
    let store = storeWithoutCopies()
    var commands: [[String: Any]] = []
    store.sendCommand = { commands.append($0) }
    send(store, windowsOf("A", profile: nil, seq: 1, focused: 1, at: 300, [(1, ["Mail"], false)]))
    store.dockedWindowProfile = workProfile
    store.dockedWindowTitle = title
    store.dockedLikeWindowCount = likeWindows
    store.dockedWindowSettled = true
    return (store, { commands })
}

do {
    // After a reload, Work's copy (B) gets no windows at all, though its window is open and in front.
    let (store, _) = dockedToWork("Work — Docs")
    send(store, windowsOf("B", profile: workProfile, seq: 1, at: 200, []))
    let work = ProfileKey(rawValue: workProfile)
    check(store.unseenDockedWindow == TabStore.UnseenWindow(profile: work, instance: "B"), "Work's copy lists no window: the docked window is unseen")
    check(store.currentWindow == nil, "no other profile's window is shown for it, though A reports a focused one")
    check(store.currentWindowProfile == work && store.currentPinnedList == .pinned(work), "its own profile's Favorites and Pinned are")
    store.dockedWindowSettled = false
    check(store.unseenDockedWindow == nil, "not before it has been open long enough for its copy to report it")
    store.dockedWindowSettled = true

    // The copy starts listing it: the full list comes back at once.
    send(store, windowsOf("B", profile: workProfile, seq: 2, focused: 7, at: 400, [(7, ["Docs"], false)]))
    check(store.unseenDockedWindow == nil && store.currentWindow?.instance == "B" && store.currentWindow?.window.id == 7,
          "once the copy lists the window, its own tabs are shown")
}

do {
    // B sees a window opened after the reload, but not the docked one, which was open before.
    let (store, _) = dockedToWork("Work — Docs", likeWindows: 2)
    send(store, windowsOf("B", profile: workProfile, seq: 1, focused: 8, at: 400, [(8, ["New"], false)]))
    check(store.unseenDockedWindow?.instance == "B" && store.currentWindow == nil, "two Work windows, the copy lists one that isn't this: unseen")
    store.dockedLikeWindowCount = 1
    check(store.unseenDockedWindow == nil, "the copy lists every Work window: only behind on a title")
    store.dockedLikeWindowCount = nil
    check(store.unseenDockedWindow != nil, "without a count, a title that fits none of its windows is unseen")

    // A tab switch in a window the copy can see, before its report: another of its tabs has the title.
    send(store, windowsOf("B", profile: workProfile, seq: 2, focused: 7, at: 500, [(7, ["Docs", "Mail"], false)]))
    store.dockedWindowTitle = "Work — Mail"
    check(store.unseenDockedWindow == nil && store.currentWindow?.instance == "B", "any tab's title fits, not only the active one's")
}

do {
    // Work has no live copy (Side Tabs is off there): not unseen; SafariProfiles shows its row to turn it on.
    let (store, _) = dockedToWork("Work — Docs")
    check(store.unseenDockedWindow == nil, "a profile without a live copy isn't unseen")
    store.dockedWindowProfile = nil
    check(store.unseenDockedWindow == nil, "nor a window whose profile isn't known")
}

do {
    // A private window: the default profile's copy is the one that should list it.
    let store = storeWithoutCopies()
    send(store, windowsOf("A", profile: nil, seq: 1, focused: 1, at: 300, [(1, ["Mail"], false)]))
    store.dockedWindowIsPrivate = true
    store.dockedWindowTitle = "Apple, Private Browsing"
    store.dockedLikeWindowCount = 1
    store.dockedWindowSettled = true
    check(store.unseenDockedWindow == TabStore.UnseenWindow(profile: nil, instance: "A"), "the default copy lists no private window: unseen")
    check(store.currentWindow == nil && store.currentWindowProfile == nil, "and the default profile's window isn't shown for it, nor its lists")
    send(store, windowsOf("A", profile: nil, seq: 2, focused: 2, at: 400, [(1, ["Mail"], false), (2, ["Apple"], true)]))
    check(store.unseenDockedWindow == nil && store.currentWindow?.window.id == 2, "once it lists the private window, that's shown")
}

do {
    // A pinned item clicked in an unseen window opens through its profile's copy, in a window it can see.
    let (store, sent) = dockedToWork("Work — Docs", likeWindows: 2)
    send(store, windowsOf("B", profile: workProfile, seq: 1, at: 400, [(8, ["New"], false)]))
    store.open(Bookmark(title: "Docs", url: "https://example.com/docs"))
    let create = sent().last
    check(create?["action"] as? String == "create" && create?["windowId"] as? Int == 8 && create?["focus"] as? Bool == true
          && create?["instance"] as? String == "B", "in Work's window its copy can see, brought forward")

    // And when it sees none, in a new window of the profile.
    let (alone, sentAlone) = dockedToWork("Work — Docs")
    send(alone, windowsOf("B", profile: workProfile, seq: 1, at: 200, []))
    alone.open(Bookmark(title: "Docs", url: "https://example.com/docs"))
    let open = sentAlone().last
    check(open?["action"] as? String == "openWindow" && open?["instance"] as? String == "B" && open?["url"] as? String == "https://example.com/docs",
          "with no window it can see, a new window of the profile")
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
/// `from` is the extension copy that sends it, and `profile` that copy's profile (nil: the default one).
func pagesSnapshot(
    seq: Int,
    from profile: String = instance,
    in profileID: String? = nil,
    focused: Int = 1,
    startedAt: Double? = nil,
    _ windows: [(id: Int, tabs: [(id: Int, url: String)])],
    active: Set<Int> = []
) -> [String: Any] {
    var object: [String: Any] = ["type": "snapshot", "instance": profile, "seq": seq, "focusedWindowId": focused, "lastFocusedWindowId": focused,
     "focusChangedAt": Double(seq), "startedAt": startedAt ?? nowMilliseconds() + 1,
     "windows": windows.map { window -> [String: Any] in
         ["id": window.id, "focused": window.id == focused, "incognito": false,
          "tabs": window.tabs.enumerated().map { position, tab -> [String: Any] in
              ["id": tab.id, "windowId": window.id, "index": position, "title": "Page \(tab.id)", "url": tab.url,
               "active": active.contains(tab.id), "pinned": false, "audible": false, "muted": false, "loading": false]
          }]
     }]
    if let profileID { object["profile"] = profileID }
    return object
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

/// Adds a bookmark for `url` to `list` (the default profile's Favorites, where #25's bookmarks went) and returns it.
func bookmark(_ store: TabStore, _ url: String, to list: BookmarkList = .favorites(.defaultProfile)) -> Bookmark {
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
    store.addBookmark(from: store.tab(for: TabKey(instance: instance, tabId: 3))!, instance: instance, to: .favorites(.defaultProfile), at: 0)
    let dragged = store.bookmarks(in: .favorites(.defaultProfile))[0]
    check(dragged.url == "https://example.com/3", "a tab dragged onto Bookmarks makes a bookmark of its page")
    check(store.openTab(for: dragged)?.id == 3, "which owns the tab")
    check(listedIds(store) == [1, 2, 4], "so the tab moves up out of Tabs")

    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (2, "https://example.com/2"), (3, elsewhere), (4, "https://example.com/4")])], active: [3]))
    store.replaceBookmarkWithCurrentPage(dragged)
    check(store.bookmarks(in: .favorites(.defaultProfile))[0].url == elsewhere, "Replace with Current Page saves the tab's current page as the bookmark's")
    check(store.openTab(for: store.bookmarks(in: .favorites(.defaultProfile))[0])?.id == 3, "and the tab stays the bookmark's")

    store.removeBookmark(store.bookmarks(in: .favorites(.defaultProfile))[0])
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
    let work = "WORK-PROFILE"
    send(store, pagesSnapshot(seq: 1, [(1, [(1, "https://example.com/1")])], active: [1]))
    let saved = bookmark(store, news)
    let docs = bookmark(store, "https://docs.example/")
    let workSaved = bookmark(store, news, to: .favorites(ProfileKey(rawValue: work)))
    openAndCreate(store, saved, commands: { sent }, tabId: 10)
    openAndCreate(store, docs, commands: { sent }, tabId: 12)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, elsewhere), (12, "https://docs.example/")])], active: [10]))
    send(store, pagesSnapshot(seq: 3, from: other, in: work, focused: 5, [(5, [(50, "https://example.com/5")])], active: [50]))
    openAndCreate(store, workSaved, commands: { sent }, tabId: 51, from: other)
    send(store, pagesSnapshot(seq: 4, from: other, in: work, focused: 5, [(5, [(50, "https://example.com/5"), (51, elsewhere)])], active: [51]))
    check(store.bookmarkTabs.owners.count == 3, "three tabs belong to bookmarks before the restart")
    store.save()

    let reloaded = TabStore(stateURL: url)
    check(reloaded.bookmarkTabs.owners.count == 3, "the links are read back from state.json")
    // Safari kept running. Meanwhile the docs tab closed, and a tab went to the docs page.
    send(reloaded, pagesSnapshot(seq: 5, [(1, [(1, "https://example.com/1"), (10, elsewhere), (13, "https://docs.example/")])], active: [10]))
    check(reloaded.openTab(for: saved)?.id == 10, "a bookmark's tab is still its own after Side Tabs restarts, though it browsed away")
    check(reloaded.openTab(for: docs) == nil, "one that closed meanwhile is closed")
    check(listedIds(reloaded) == [1, 13], "and a tab on a bookmark's page that wasn't its tab stays under Tabs")
    check(reloaded.bookmarkTabs.owners[TabKey(instance: other, tabId: 51)] == workSaved.id, "a profile that hasn't reported yet keeps its links")
    send(reloaded, pagesSnapshot(seq: 6, from: other, in: work, focused: 5, [(5, [(50, "https://example.com/5"), (51, elsewhere)])], active: [51]))
    check(reloaded.openTab(for: workSaved)?.id == 51, "and has them when it does")
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
    check(store.bookmarks(in: .favorites(.defaultProfile)).map(\.title) == ["Old"], "an older state.json without bookmarks' tabs still loads its bookmarks")
}

// MARK: - Favorites and a Pinned list for each profile (#34, #38)

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

/// The favorites of `profile` (the default one unless given).
func favorites(_ store: TabStore, _ profile: ProfileKey = .defaultProfile) -> [Bookmark] {
    store.bookmarks(in: .favorites(profile))
}

/// The pinned items of `profile` (the default one unless given).
func pinned(_ store: TabStore, _ profile: ProfileKey = .defaultProfile) -> [Bookmark] {
    store.bookmarks(in: .pinned(profile))
}

do {
    // Each profile has its own Favorites and Pinned list, which follow the window in front (#38).
    let spaces = Spaces()
    let store = spaces.store
    check(store.currentWindowProfile == .defaultProfile, "a window of the copy that sends no profile is the default profile's")
    check(store.currentFavoritesList == .favorites(.defaultProfile) && store.currentPinnedList == .pinned(.defaultProfile),
          "and the sidebar shows the default profile's Favorites and Pinned list")
    store.addBookmarkForCurrentTab()
    check(pinned(store).map(\.url) == ["https://example.com/1"], "Add Bookmark pins the current tab in the profile's Pinned list")
    check(favorites(store).isEmpty, "not in Favorites")
    check(pinned(store).first.flatMap(store.openTab(for:))?.id == 1 && listedIds(store) == [2], "the pinned item owns the tab, which leaves Tabs")
    let home = bookmark(store, news)
    check(favorites(store).map(\.id) == [home.id], "a favorite added here is the default profile's")

    spaces.show(.work)
    check(store.currentWindowProfile == work, "a window of another copy is the profile whose UUID Safari sends with it")
    check(store.currentFavoritesList == .favorites(work) && store.currentPinnedList == .pinned(work),
          "switching to it swaps Favorites and Pinned together, at once")
    check(favorites(store, work).isEmpty && pinned(store, work).isEmpty, "another profile starts with neither")
    let current = store.currentWindow!
    check(!store.bookmarkIds(shownIn: current.window, instance: current.instance).contains(home.id),
          "the default profile's favorite doesn't show in Work's window")
    store.addBookmarkForCurrentTab()
    let office = bookmark(store, "https://work.example/", to: .favorites(work))
    check(pinned(store, work).map(\.url) == ["https://example.com/50"] && favorites(store, work).map(\.id) == [office.id],
          "Work gets lists of its own")
    check(pinned(store).count == 1 && favorites(store).map(\.id) == [home.id], "and the default profile's stay as they were")

    spaces.show(.personal)
    check(store.currentFavoritesList == .favorites(.defaultProfile) && listedIds(store) == [2],
          "back in the default profile's window, its own lists show again, its pinned tab still out of Tabs")
    store.dockedWindowTitle = "Work — Page 50"
    check(store.currentFavoritesList == .favorites(work) && store.currentPinnedList == .pinned(work),
          "both follow the window the sidebar is docked to, as soon as its title says which")
}

do {
    // A private window belongs to no profile: it shows Tabs only, and offers nothing to add to (#38).
    let spaces = Spaces()
    let store = spaces.store
    let home = bookmark(store, news)
    _ = bookmark(store, "https://docs.example/", to: .pinned(.defaultProfile))
    spaces.show(.privateBrowsing)
    check(store.currentWindowProfile == nil, "a private window belongs to no profile, though the default profile's copy reports it")
    check(store.currentFavoritesList == nil && store.currentPinnedList == nil, "so it has no Favorites and no Pinned list")
    let current = store.currentWindow!
    check(store.bookmarkIds(shownIn: current.window, instance: current.instance).isEmpty, "and shows no favorite or pinned item")
    let sent = spaces.commands.count
    store.addBookmarkForCurrentTab()
    check(store.bookmarkLists.all.count == 2 && spaces.commands.count == sent, "Add Bookmark does nothing there")
    check(listedIds(store) == [30], "its tab stays under Tabs")
    // What a click would do, if anything there offered one: the favorite's page opens, but the tab isn't its.
    spaces.openAndCreate(home, tabId: 31)
    check(store.bookmarkTabs.owners.isEmpty && listedIds(store) == [30, 31], "a favorite never owns a tab in a private window")
}

do {
    // #25's rules hold for favorites and pinned items alike.
    for list in [BookmarkList.favorites(.defaultProfile), .pinned(.defaultProfile)] {
        let spaces = Spaces()
        let store = spaces.store
        let name = list == .favorites(.defaultProfile) ? "a favorite" : "a pinned item"
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
    // A favorite never owns a tab of another profile's window (#38).
    let spaces = Spaces()
    let store = spaces.store
    let home = bookmark(store, news)
    spaces.openAndCreate(home, tabId: 10)
    spaces.show(.work)
    check(store.openTab(for: home) == nil, "a default-profile favorite open in its own window is nothing in Work's")
    // Neither of these can be done from the sidebar, which shows Work's lists here; the store refuses them anyway.
    spaces.openAndCreate(home, tabId: 52)
    check(store.bookmarkTabs.owners == [spaces.key(10): home.id], "opening it from a Work window doesn't give it a tab there")
    store.addBookmark(from: spaces.tab(50), instance: workCopy, to: .favorites(.defaultProfile))
    check(store.bookmarkTabs.owners.count == 1 && listedIds(store) == [50, 51, 52],
          "nor does making a default-profile favorite of a Work tab: the tab stays under Tabs")
    let office = bookmark(store, "https://work.example/", to: .favorites(work))
    let opened = spaces.openAndCreate(office, tabId: 53)
    check(opened?.copy == workCopy && opened?.windowId == 5 && store.openTab(for: office)?.id == 53,
          "a Work favorite opens in the Work window, through Work's copy, and owns its tab")
    check(store.bookmarkTabKeys == [spaces.key(10), spaces.key(53)], "cleanup keeps exactly the favorites' own tabs open")
}

do {
    // Dragging a tab onto Favorites or Pinned.
    let spaces = Spaces()
    let store = spaces.store
    store.addBookmark(from: spaces.tab(2), instance: defaultCopy, to: .pinned(.defaultProfile), at: 0)
    check(pinned(store).first?.url == "https://example.com/2", "a tab dropped on Pinned becomes a pinned item")
    check(pinned(store).first.flatMap(store.openTab(for:))?.id == 2 && listedIds(store) == [1], "that owns the tab")
    store.addBookmark(from: spaces.tab(1), instance: defaultCopy, to: .favorites(.defaultProfile), at: 0)
    check(favorites(store).first?.url == "https://example.com/1" && favorites(store).first.flatMap(store.openTab(for:))?.id == 1,
          "a tab dropped on Favorites becomes a favorite that owns the tab")
    check(listedIds(store).isEmpty, "so both left Tabs")
}

do {
    // Moving between Favorites and Pinned, and reordering, within the profile.
    let spaces = Spaces()
    let store = spaces.store
    let saved = bookmark(store, news)
    let docs = bookmark(store, "https://docs.example/")
    spaces.openAndCreate(saved, tabId: 10)

    store.moveBookmark(saved.id, to: .pinned(.defaultProfile), at: 0)
    check(favorites(store).map(\.id) == [docs.id] && pinned(store).map(\.id) == [saved.id],
          "Move to Pinned takes a favorite out of the profile's Favorites into its Pinned list")
    check(store.openTab(for: saved)?.id == 10 && listedIds(store) == [1, 2], "keeping its tab")
    store.moveBookmark(saved.id, to: .favorites(.defaultProfile), at: 1)
    check(favorites(store).map(\.id) == [docs.id, saved.id] && pinned(store).isEmpty,
          "Move to Favorites, or a drop there, puts it back where it's dropped")
    check(store.openTab(for: saved)?.id == 10, "still keeping its tab")

    store.moveBookmark(saved.id, to: .pinned(work), at: 0)
    store.moveBookmark(docs.id, to: .favorites(work), at: 0)
    check(favorites(store).map(\.id) == [docs.id, saved.id] && pinned(store, work).isEmpty && favorites(store, work).isEmpty,
          "a move to another profile's list is refused: lists stay within their profile")

    store.moveBookmark(saved.id, to: .favorites(.defaultProfile), at: 0)
    check(favorites(store).map(\.id) == [saved.id, docs.id], "favorites reorder by dragging")
    store.moveBookmark(docs.id, to: .pinned(.defaultProfile), at: 5)
    store.moveBookmark(saved.id, to: .pinned(.defaultProfile), at: 0)
    check(pinned(store).map(\.id) == [saved.id, docs.id], "a drop past the end of a list goes at its end")
    store.moveBookmark(saved.id, to: .pinned(.defaultProfile), at: 1)
    check(pinned(store).map(\.id) == [docs.id, saved.id], "and pinned items reorder too")
    let ids = store.bookmarkLists.all.map(\.id)
    check(Set(ids).count == ids.count && ids.count == 2, "a bookmark is in one list only, with its own id")
}

do {
    // Everything survives saving and loading, and `bookmarks` holds the default profile's favorites (#38).
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    let spaces = Spaces(stateURL: url)
    let store = spaces.store
    let home = bookmark(store, news)
    let here = bookmark(store, "https://docs.example/", to: .pinned(.defaultProfile))
    let there = bookmark(store, "https://work.example/", to: .pinned(work))
    let office = bookmark(store, "https://office.example/", to: .favorites(work))
    spaces.openAndCreate(here, tabId: 10)
    spaces.openAndCreate(home, tabId: 11)
    spaces.show(.work)
    spaces.openAndCreate(there, tabId: 52)
    spaces.openAndCreate(office, tabId: 53)
    store.beginRename(.bookmark(there.id))
    store.commitRename("Renamed")
    check(pinned(store, work).first?.title == "Renamed", "a pinned item can be renamed")
    store.save()

    let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    let urls = { (list: Any?) in (list as? [[String: Any]])?.compactMap { $0["url"] as? String } ?? [] }
    check(urls(json["bookmarks"]) == [news], "state.json keeps the default profile's favorites under bookmarks, for Side Tabs 1.2.5")
    let savedFavorites = json["favorites"] as? [String: Any] ?? [:]
    check(urls(savedFavorites["default"]) == [news] && urls(savedFavorites[workUUID]) == ["https://office.example/"] && savedFavorites.count == 2,
          "and every profile's favorites under favorites, by the profile's key")
    let savedPinned = json["pinned"] as? [String: Any] ?? [:]
    check(urls(savedPinned["default"]) == ["https://docs.example/"] && urls(savedPinned[workUUID]) == ["https://work.example/"],
          "and each profile's Pinned list under pinned")

    let reloaded = Spaces(stateURL: url, tabsOf: spaces)
    check(reloaded.store.bookmarkLists == store.bookmarkLists, "the lists load back as they were, with their ids, names and order")
    check(reloaded.store.bookmarkTabs.owners == store.bookmarkTabs.owners, "and so do their tabs")
    check(reloaded.store.currentFavoritesList == .favorites(.defaultProfile) && reloaded.store.openTab(for: here)?.id == 10
          && reloaded.store.openTab(for: home)?.id == 11, "the default profile's window shows its own lists, with their tabs")
    reloaded.show(.work)
    check(pinned(reloaded.store, work).map(\.title) == ["Renamed"] && favorites(reloaded.store, work).map(\.id) == [office.id],
          "and Work's window shows Work's")
    check(reloaded.store.openTab(for: there)?.id == 52 && reloaded.store.openTab(for: office)?.id == 53 && listedIds(reloaded.store) == [50, 51],
          "with their tabs still theirs")
}

do {
    // An old state.json, with `bookmarks` only: they're the default profile's favorites, and other profiles have none.
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    try! FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
    let old = #"{"bookmarks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","url":"https://old.example/"},{"id":"7A9619FF-8B86-D011-B42D-00C04FC964FF","title":"Older","url":"https://older.example/"}],"names":[],"orphanNames":{},"bookmarkTabs":[{"instance":"copy-default","tabId":2,"bookmark":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}],"instances":["copy-default"]}"#
    try! old.write(to: url, atomically: true, encoding: .utf8)
    let spaces = Spaces(stateURL: url)
    let store = spaces.store
    check(favorites(store).map(\.title) == ["Old", "Older"], "an old state.json's bookmarks load as the default profile's favorites, in order")
    check(store.bookmarkLists.pinned.isEmpty && store.bookmarkLists.favorites.keys.elementsEqual([.defaultProfile]),
          "no other profile has any favorites, and nobody has anything pinned")
    check(favorites(store).first.flatMap(store.openTab(for:))?.id == 2 && listedIds(store) == [1], "a bookmark's tab stays its own as a favorite")
    spaces.show(.work)
    check(store.currentWindow.map { store.bookmarkIds(shownIn: $0.window, instance: $0.instance).isEmpty } == true, "Work's window shows none of them")
    store.save()
    let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    let ids = { (list: Any?) in (list as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? [] }
    check(ids(json["bookmarks"]) == ["6F9619FF-8B86-D011-B42D-00C04FC964FF", "7A9619FF-8B86-D011-B42D-00C04FC964FF"],
          "saved again, they're still under bookmarks with their ids")
    check(ids((json["favorites"] as? [String: Any])?["default"]) == ids(json["bookmarks"]), "and under favorites as the default profile's")
}

do {
    // A state.json from when favorites were shared (#34): a favorite could own a tab in another profile's
    // window or a private one. It's the default profile's favorite now, and lets go of those tabs.
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    let shared = #"{"bookmarks":[{"id":"\#(id)","title":"Shared","url":"https://news.example/"}],"pinned":{},"names":[],"orphanNames":{},"bookmarkTabs":[{"instance":"copy-default","tabId":2,"bookmark":"\#(id)"},{"instance":"copy-default","tabId":30,"bookmark":"\#(id)"},{"instance":"copy-work","tabId":51,"bookmark":"\#(id)"}],"instances":["copy-default","copy-work"]}"#
    try! shared.write(to: url, atomically: true, encoding: .utf8)
    let spaces = Spaces(stateURL: url)
    let store = spaces.store
    check(favorites(store).map(\.id.uuidString) == [id], "a shared favorite becomes the default profile's")
    check(store.bookmarkTabs.owners == [spaces.key(2): UUID(uuidString: id)!], "it keeps its tab in the default profile's window only")
    spaces.show(.work)
    check(listedIds(store) == [50, 51], "its old tab in Work's window is back under Tabs")
    spaces.show(.privateBrowsing)
    check(listedIds(store) == [30], "and so is its tab in the private window")
}

do {
    // Use `favorites` when it's there: `bookmarks` only mirrors the default profile's.
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    let file = #"{"bookmarks":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Mirror","url":"https://a.example/"}],"favorites":{"\#(workUUID)":[{"id":"7A9619FF-8B86-D011-B42D-00C04FC964FF","title":"Work","url":"https://b.example/"}]},"names":[],"orphanNames":{}}"#
    try! file.write(to: url, atomically: true, encoding: .utf8)
    let store = TabStore(stateURL: url)
    check(favorites(store).isEmpty && favorites(store, work).map(\.title) == ["Work"], "with favorites in the file, bookmarks isn't read again")
}

do {
    // Ids stay unique across every list, even in a state.json edited by hand.
    storeCount += 1
    let url = stateFolder.appending(path: "state-\(storeCount).json")
    let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    let edited = #"{"bookmarks":[],"favorites":{"default":[{"id":"\#(id)","title":"A","url":"https://a.example/"}],"\#(workUUID)":[{"id":"\#(id)","title":"C","url":"https://c.example/"}]},"pinned":{"default":[{"id":"\#(id)","title":"B","url":"https://b.example/"}]},"names":[],"orphanNames":{}}"#
    try! edited.write(to: url, atomically: true, encoding: .utf8)
    let store = TabStore(stateURL: url)
    let ids = store.bookmarkLists.all.map(\.id)
    check(ids.count == 3 && Set(ids).count == 3, "a repeated id gets a new one, so each bookmark keeps its own")
    check(favorites(store).first?.id.uuidString == id, "the default profile's favorite keeps the id it had")
}

do {
    // After Safari restarts, a favorite or pinned item only gets back a tab of its own profile.
    let spaces = Spaces()
    let store = spaces.store
    let pinnedItem = bookmark(store, news, to: .pinned(work))
    let favorite = bookmark(store, "https://work.example/", to: .favorites(work))
    spaces.show(.work)
    spaces.openAndCreate(pinnedItem, tabId: 52)
    spaces.openAndCreate(favorite, tabId: 53)
    store.safariDidTerminate()
    send(store, spaceSnapshot(seq: 1, from: "restarted-default", focused: 7, focusChangedAt: 100,
                              [(7, false, [(70, news), (71, "https://work.example/")]), (9, true, [(90, "https://work.example/")])], active: [70, 90]))
    check(store.bookmarkTabs.owners.isEmpty, "restored tabs of another profile, or a private window, on their pages don't become theirs")
    check(listedIds(store) == [70, 71], "and stay under Tabs")
    send(store, spaceSnapshot(seq: 1, from: "restarted-work", profile: workUUID, focused: 8, focusChangedAt: 101,
                              [(8, false, [(80, news), (81, "https://work.example/")])], active: [80]))
    check(store.bookmarkTabs.owners == [TabKey(instance: "restarted-work", tabId: 80): pinnedItem.id, TabKey(instance: "restarted-work", tabId: 81): favorite.id],
          "tabs of their own profile do")
}

// MARK: - Copies of the extension that go quiet or are replaced (#31)

/// A message other than a snapshot from a copy of the extension. `profile` is what the extension's handler
/// adds: the profile's UUID, absent for the default profile.
func message(_ type: String, from copy: String, in profile: String? = nil, _ fields: [String: Any] = [:]) -> [String: Any] {
    var object: [String: Any] = ["type": type, "instance": copy]
    if let profile { object["profile"] = profile }
    return object.merging(fields) { $1 }
}

/// Sends a message and returns the store's reply.
func reply(_ store: TabStore, _ object: [String: Any]) -> [String: Any] {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return store.handleMessage(type: object["type"] as! String, payload: data, object: object)
}

do {
    // A copy that sends nothing for 30 s is quiet: its windows are hidden until it speaks again.
    let (store, _) = makeStore()
    var ahead: TimeInterval = 0
    store.clock = { Date().addingTimeInterval(ahead) }
    check(store.liveInstances == [instance], "a copy that has sent a snapshot is live")
    check(store.hasLiveCopy(profile: nil), "so its profile, the default one, has a live copy")
    ahead = 29
    store.noteQuietCopies()
    check(store.currentWindow?.window.id == 1, "29 s without a message isn't quiet yet")
    _ = reply(store, message("heartbeat", from: instance, ["seq": 1]))
    ahead = 29 + 25
    store.noteQuietCopies()
    check(store.currentWindow?.window.id == 1, "a heartbeat counts as a message: 25 s after it the copy isn't quiet")
    ahead = 29 + 31
    store.noteQuietCopies()
    check(store.liveInstances.isEmpty, "after 30 s without any message the copy is quiet")
    check(store.currentWindow == nil, "and its window isn't shown")
    check(store.snapshots[instance] != nil, "but its snapshot is kept")
    check(!store.hasLiveCopy(profile: nil), "and its profile has no live copy")
    let answer = reply(store, message("heartbeat", from: instance, ["seq": 1]))
    check(store.currentWindow?.window.id == 1, "when it speaks again, its window is shown again")
    check(answer["needSnapshot"] as? Bool == true, "and it's asked for a new snapshot, though it had sent its last one")
    check(store.liveInstances == [instance] && store.hasLiveCopy(profile: nil), "and it's live")
    let next = reply(store, message("heartbeat", from: instance, ["seq": 1]))
    check(next["needSnapshot"] as? Bool == false, "after that, heartbeats are answered as before")
}

do {
    // One profile's copy goes quiet; another's goes on. Only the quiet one's windows are hidden, whatever the
    // docked window's title says.
    let (store, commands) = makeStore()
    var ahead: TimeInterval = 0
    store.clock = { Date().addingTimeInterval(ahead) }
    let work = "WORK-PROFILE"
    send(store, pagesSnapshot(seq: 2, from: "work-copy", in: work, focused: 5, [(5, [(50, "https://example.com/5")])], active: [50]))
    check(store.currentWindow?.instance == "work-copy", "the window focused last, the work profile's, is shown")
    check(store.hasLiveCopy(profile: work) && store.hasLiveCopy(profile: nil), "both profiles have a live copy")
    store.dockedWindowTitle = "Work — Page 50"
    check(store.currentWindow?.window.id == 5, "the docked window's title picks the work window")
    ahead = 20
    _ = reply(store, message("heartbeat", from: instance, ["seq": 1]))
    ahead = 31
    store.noteQuietCopies()
    check(store.liveInstances == [instance], "the copy that went silent is quiet, the other isn't")
    check(!store.hasLiveCopy(profile: work) && store.hasLiveCopy(profile: nil), "so only the default profile has a live copy")
    check(store.currentWindow?.instance == instance, "the quiet copy's window isn't shown, even though the docked window's title fits it")
    let before = commands().filter { $0["action"] as? String == "snapshot" }.count
    store.dockedWindowTitle = "Work — Page 51"
    store.dockedWindowTitle = "Work — Page 50"
    check(commands().filter { $0["action"] as? String == "snapshot" }.count > before,
        "a docked window only a quiet copy reports counts as unknown, so Safari is asked for snapshots")
}

do {
    // Whether the extension lacks website access is told from the tabs of the copies that are live, not from
    // what a quiet copy last said.
    let (store, _) = makeStore()
    var ahead: TimeInterval = 0
    store.clock = { Date().addingTimeInterval(ahead) }
    var bare = pagesSnapshot(seq: 1, from: "bare-copy", in: "BARE-PROFILE", [(9, [(90, "")])])
    bare["windows"] = [["id": 9, "focused": false, "incognito": false, "tabs": [["id": 90, "windowId": 9, "index": 0,
        "active": true, "pinned": false, "audible": false, "muted": false, "loading": false]]]]
    send(store, bare)
    check(!store.lacksWebsiteAccess, "while one copy's tabs show URLs, there's website access")
    ahead = 20
    _ = reply(store, message("heartbeat", from: "bare-copy", ["seq": 1]))
    ahead = 31
    store.noteQuietCopies()
    check(store.lacksWebsiteAccess, "once that copy is quiet, the live copy's tabs without URLs say there isn't")
}

do {
    // When the extension reloads or is reinstalled, a new copy of each profile starts. Its first message, of any
    // kind, replaces the old copy of its profile, which has stopped.
    let (store, _) = makeStore()
    _ = reply(store, message("hello", from: "new-copy", ["launchApp": true]))
    check(store.snapshots[instance] == nil, "a newer copy of the same profile replaces the old one, and the old one's snapshot goes")
    check(store.liveInstances == ["new-copy"], "only the newer copy is live")
    check(store.currentWindow == nil, "the old copy's window isn't shown")
    send(store, pagesSnapshot(seq: 1, from: "new-copy", focused: 7, [(7, [(70, "https://example.com/1")])], active: [70]))
    check(store.currentWindow?.instance == "new-copy" && store.currentWindow?.window.id == 7, "the new copy's window is")

    // Messages from the old copy that were still on their way are ignored.
    send(store, snapshotObject(seq: 9, active: 2))
    check(store.snapshots[instance] == nil, "a late snapshot from the replaced copy doesn't bring it back")
    let answer = reply(store, message("heartbeat", from: instance, ["seq": 9]))
    check(answer["needSnapshot"] == nil && !store.liveInstances.contains(instance), "nor does a late heartbeat")
    check(store.currentWindow?.instance == "new-copy", "the new copy's window stays shown")
}

do {
    // Copies are matched by profile: the UUID the extension's handler adds, or none for the default profile.
    let (store, _) = makeStore()
    send(store, pagesSnapshot(seq: 1, from: "work-copy", in: "WORK", focused: 5, [(5, [(50, "https://example.com/5")])]))
    send(store, pagesSnapshot(seq: 1, from: "home-copy", in: "HOME", focused: 6, [(6, [(60, "https://example.com/6")])]))
    check(Set(store.snapshots.keys) == [instance, "work-copy", "home-copy"], "copies of other profiles replace nothing")
    _ = reply(store, message("heartbeat", from: "work-copy-2", in: "WORK", ["seq": 0]))
    check(store.snapshots["work-copy"] == nil, "a newer copy with the same profile UUID replaces the old one")
    check(Set(store.snapshots.keys) == [instance, "home-copy"], "and only that one")
    check(store.liveInstances == [instance, "home-copy", "work-copy-2"], "the newer copy is live, though it hasn't sent a snapshot yet")
    check(store.hasLiveCopy(profile: "WORK") && store.hasLiveCopy(profile: "HOME") && !store.hasLiveCopy(profile: "OTHER"),
        "and each profile with a running copy has a live copy")
    _ = reply(store, message("heartbeat", from: "work-copy-2", ["seq": 0]))
    check(store.hasLiveCopy(profile: "WORK"), "a message without a profile from a copy known to have one doesn't make it the default profile's")
    _ = reply(store, message("hello", from: "default-copy-2"))
    check(store.liveInstances == ["home-copy", "work-copy-2", "default-copy-2"],
        "so a newer copy of the default profile replaces only the default profile's old copy")
}

do {
    // A replaced copy that keeps sending for 30 s is running after all (a second Safari, say). It's taken back,
    // and doesn't replace the newer copy in turn.
    let (store, _) = makeStore()
    var ahead: TimeInterval = 0
    store.clock = { Date().addingTimeInterval(ahead) }
    _ = reply(store, message("heartbeat", from: "second-copy", ["seq": 0]))
    check(store.snapshots[instance] == nil, "the newer copy replaces it")
    ahead = 10
    _ = reply(store, message("heartbeat", from: instance, ["seq": 1]))
    check(!store.liveInstances.contains(instance), "its heartbeat soon after is taken for one that was on its way")
    ahead = 31
    let answer = reply(store, message("heartbeat", from: instance, ["seq": 1]))
    check(store.liveInstances == [instance, "second-copy"], "still sending 30 s after it was replaced, it's taken back")
    check(answer["needSnapshot"] as? Bool == true, "and asked for a snapshot")
    send(store, snapshotObject(seq: 2, active: 1))
    check(store.snapshots[instance] != nil, "which is applied")
    _ = reply(store, message("heartbeat", from: "second-copy", ["seq": 0]))
    check(store.liveInstances == [instance, "second-copy"], "and neither copy replaces the other after that")
}

do {
    // Safari quits: every copy is gone. After it starts again, its copies are new.
    let (store, _) = makeStore()
    store.safariDidTerminate()
    check(store.liveInstances.isEmpty && !store.hasLiveCopy(profile: nil), "after Safari quits, no copy is live")
    send(store, pagesSnapshot(seq: 1, from: "after-restart", focused: 3, [(3, [(30, "https://example.com/1")])], active: [30]))
    check(store.liveInstances == ["after-restart"] && store.currentWindow?.window.id == 3, "the copy that starts with Safari is")
}

do {
    // A quiet copy keeps its bookmarks' tabs, cleanup's clocks and custom names, so a pause under load loses
    // nothing. Once a newer copy of its profile replaces it, they go through the paths for a copy that's gone:
    // the clocks are dropped, and the bookmark and the name go to the new copy's tab on the same page.
    let (store, commands) = makeStore()
    var ahead: TimeInterval = 0
    store.clock = { Date().addingTimeInterval(ahead) }
    store.cleanup.setOn(true, tabs: store.snapshots)
    let saved = bookmark(store, news)
    openAndCreate(store, saved, commands: commands, tabId: 10)
    send(store, pagesSnapshot(seq: 2, [(1, [(1, "https://example.com/1"), (10, news)])], active: [1]))
    store.beginRename(.tab(TabKey(instance: instance, tabId: 1)))
    store.commitRename("Mine")
    let old = { (tabId: Int) in TabKey(instance: instance, tabId: tabId) }
    check(store.bookmarkTabs.owners[old(10)] == saved.id, "the bookmark has its tab")
    check(store.cleanup.lastViewed[old(1)] != nil && store.cleanup.lastViewed[old(10)] != nil, "the tabs have clocks")
    check(store.hasCustomName(old(1)), "and a tab has a custom name")

    ahead = 31
    store.noteQuietCopies()
    check(store.currentWindow == nil, "the copy is quiet")
    check(store.bookmarkTabs.owners[old(10)] == saved.id, "a quiet copy's bookmark's tab stays the bookmark's")
    check(store.cleanup.lastViewed[old(1)] != nil && store.cleanup.lastViewed[old(10)] != nil, "its tabs keep their clocks")
    check(store.hasCustomName(old(1)), "and their custom names")

    // Another profile's copy starting meanwhile takes none of it.
    send(store, pagesSnapshot(seq: 1, from: "work-copy", in: "WORK", focused: 5, [(5, [(50, news), (51, "https://example.com/1")])], active: [50]))
    check(store.bookmarkTabs.owners[old(10)] == saved.id, "a new copy of another profile starting meanwhile leaves the bookmark's tab alone")
    check(store.bookmarkTabs.owners[TabKey(instance: "work-copy", tabId: 50)] == nil, "and its tab on the saved page doesn't take it")
    check(store.hasCustomName(old(1)) && !store.hasCustomName(TabKey(instance: "work-copy", tabId: 51)), "nor the custom name")
    check(store.cleanup.lastViewed[old(1)] != nil, "and the clocks stay")

    send(store, pagesSnapshot(seq: 3, [(1, [(1, "https://example.com/1"), (10, news)])], active: [10]))
    check(store.currentWindow?.instance == instance, "when the copy speaks again, its window is back")
    check(store.openTab(for: saved)?.id == 10, "with the bookmark's tab still its own")

    // Side Tabs is turned off in the profile, and later on again: a newer copy of the profile starts.
    ahead = 70
    store.noteQuietCopies()
    send(store, pagesSnapshot(seq: 1, from: "newer-copy", focused: 8, [(8, [(81, "https://example.com/1"), (82, news)])], active: [81]))
    check(store.snapshots[instance] == nil, "once a newer copy of its profile reports, the old copy is gone")
    check(store.bookmarkTabs.owners[old(10)] == nil, "its bookmark's tab is no longer the bookmark's")
    check(store.bookmarkTabs.owners[TabKey(instance: "newer-copy", tabId: 82)] == saved.id, "the new copy's tab on the saved page is")
    check(!store.cleanup.lastViewed.keys.contains { $0.instance == instance }, "the old copy's clocks are dropped")
    check(store.cleanup.lastViewed[TabKey(instance: "newer-copy", tabId: 81)] != nil, "and the new copy's tabs have clocks")
    let renamed = store.tab(for: TabKey(instance: "newer-copy", tabId: 81))
    check(renamed.map { store.displayTitle(for: $0, instance: "newer-copy") } == "Mine", "the custom name goes to the new copy's tab on that page")
}

// MARK: - Asking for a missing snapshot without relying on a reply (#37)

/// The `snapshot` commands sent to a copy, or to every copy.
func snapshotCommands(_ commands: [[String: Any]], to copy: String) -> Int {
    commands.filter { $0["action"] as? String == "snapshot" && $0["instance"] as? String == copy }.count
}

do {
    // Replies can be lost for minutes after the extension reloads, so when a heartbeat shows a snapshot is
    // missing, the app asks with a command as well as in the reply.
    let (store, commands) = makeStore()
    var answer = reply(store, message("heartbeat", from: instance, ["seq": 1]))
    check(snapshotCommands(commands(), to: instance) == 0 && answer["needSnapshot"] as? Bool == false,
        "a heartbeat naming the snapshot the app has asks for nothing")
    answer = reply(store, message("heartbeat", from: instance, ["seq": 3]))
    check(answer["needSnapshot"] as? Bool == true, "one naming a newer snapshot asks for it in the reply")
    check(snapshotCommands(commands(), to: instance) == 1, "and with a snapshot command to that copy")
    send(store, snapshotObject(seq: 3, active: 1))
    _ = reply(store, message("heartbeat", from: instance, ["seq": 3]))
    check(snapshotCommands(commands(), to: instance) == 1, "once the snapshot is there, no more commands")

    _ = reply(store, message("heartbeat", from: "work-copy", in: "WORK", ["seq": 0]))
    check(snapshotCommands(commands(), to: "work-copy") == 1, "a copy the app has no snapshot from is sent a snapshot command")

    // A copy that loses every reply never learns its snapshots were delivered, so its heartbeats say 0. The
    // app has its snapshot, so it doesn't make the copy build one every 5 s.
    _ = reply(store, message("heartbeat", from: instance, ["seq": 0]))
    check(snapshotCommands(commands(), to: instance) == 1, "a heartbeat saying 0 from a copy whose snapshot the app has sends no command")
}

do {
    // A copy back from being quiet is asked for a snapshot by command too.
    let (store, commands) = makeStore()
    var ahead: TimeInterval = 0
    store.clock = { Date().addingTimeInterval(ahead) }
    ahead = 31
    store.noteQuietCopies()
    _ = reply(store, message("activated", from: instance, ["windowId": 1, "tabId": 2, "seq": 2]))
    check(snapshotCommands(commands(), to: instance) == 1, "a copy that speaks again after going quiet is sent a snapshot command")
}

// MARK: - What the sidebar shows while a switch's window comes back from the Dock (#44)

/// A copy's snapshot with several windows, none focused, `lastFocused` the one it had last.
func copyWindows(_ copy: String, profile: String?, seq: Int, _ windows: [(id: Int, page: String)], lastFocused: Int?, at: Double) -> [String: Any] {
    var object: [String: Any] = [
        "type": "snapshot", "instance": copy, "seq": seq, "focusedWindowId": -1, "focusChangedAt": at,
        "windows": windows.map { window in
            ["id": window.id, "focused": false, "incognito": false,
             "tabs": [["id": window.id * 100, "windowId": window.id, "index": 0, "title": window.page,
                       "url": "https://example.com/\(window.id)", "active": true, "pinned": false, "audible": false,
                       "muted": false, "loading": false] as [String: Any]]] as [String: Any]
        },
    ]
    if let lastFocused { object["lastFocusedWindowId"] = lastFocused }
    if let profile { object["profile"] = profile }
    return object
}

let switchedWork = ProfileKey(rawValue: workProfile)

do {
    // Personal's window is in front; Work's two windows are in the Dock, the one used last is 8.
    let store = storeWithoutCopies()
    send(store, copySnapshot("A", profile: nil, seq: 1, window: 1, title: "Mail", focused: true, at: 100))
    send(store, copyWindows("B", profile: workProfile, seq: 1, [(7, "Docs"), (8, "News")], lastFocused: 8, at: 50))
    store.dockedWindowProfile = "default"
    store.dockedWindowTitle = "Personal — Mail"
    check(store.shownWindow?.instance == "A" && store.shownProfile == .defaultProfile && store.switchPreview == nil,
          "until a switch, the sidebar shows the window in front")
    let before = store.displayedContent
    check(store.sidebarFade.isOver, "no fade before a switch")

    store.beginSwitchPreview(id: 1, profile: switchedWork, guess: .window(instance: "B", windowId: 8), arrivesAt: Date().addingTimeInterval(0.4))
    check(store.shownWindow?.instance == "B" && store.shownWindow?.window.id == 8, "at the switch, the sidebar is set to show the guessed window's tabs")
    check(store.shownProfile == switchedWork && store.currentFavoritesList == .favorites(switchedWork) && store.currentPinnedList == .pinned(switchedWork),
          "and its profile's Favorites and Pinned")
    check(store.currentWindow?.instance == "A", "while the window Safari has in front is still the one commands act on")
    // Fade out, then in: never both on screen.
    check(store.sidebarFade.phase == .out(SwitchPreviewRules.fadeOut) && store.sidebarFade.opacity == 0,
          "first the old contents fade out")
    check(store.displayedContent == before && store.activeTab?.instance == "A", "and only they are on screen meanwhile, the address bar too")
    wait(SwitchPreviewRules.fadeOut + 0.1)
    if case .in(let duration) = store.sidebarFade.phase {
        check(duration > 0.15 && duration < 0.4, "then the new contents fade in, until the window lands")
    } else {
        check(false, "the new contents fade in once the old are out")
    }
    check(store.displayedContent == .window(store.shownWindow!) && store.activeTab?.instance == "B",
          "the new contents alone are on screen, the address bar too")
    let fade = store.sidebarFade

    store.refineSwitchPreview(id: 1, guess: .placeholder)
    check(store.shownContent == .placeholder(switchedWork) && store.shownWindow == nil && store.activeTab == nil,
          "a placeholder shows the profile's lists and no window's tabs")
    store.refineSwitchPreview(id: 1, guess: .window(instance: "B", windowId: 8))
    check(store.sidebarFade == fade, "a better guess replaces the first with no second fade")

    // Safari reports a window of another profile than the switch's: the guess stays.
    store.confirmSwitchPreview(profile: .defaultProfile)
    check(store.switchPreview != nil, "a report of another profile doesn't end the guess")

    // Safari reports the switch's window: the docked window is Work's window 8.
    store.dockedWindowProfile = workProfile
    store.dockedWindowTitle = "Work — News"
    store.confirmSwitchPreview(profile: switchedWork)
    check(store.switchPreview == nil, "once Safari shows the switch's profile, and the sidebar's own choice is its window, the guess ends")
    check(store.shownWindow?.instance == "B" && store.shownWindow?.window.id == 8, "a right guess: the sidebar keeps what it showed")
    check(store.sidebarFade == fade, "with no second fade")
    wait(0.5)
    check(store.sidebarFade.isOver && store.sidebarFade.opacity == 1, "and once the window has landed, the fade is over, at full opacity")
}

do {
    // A wrong guess: Safari brings window 7 forward.
    let store = storeWithoutCopies()
    send(store, copySnapshot("A", profile: nil, seq: 1, window: 1, title: "Mail", focused: true, at: 100))
    send(store, copyWindows("B", profile: workProfile, seq: 1, [(7, "Docs"), (8, "News")], lastFocused: 8, at: 50))
    store.dockedWindowProfile = "default"
    store.beginSwitchPreview(id: 1, profile: switchedWork, guess: .window(instance: "B", windowId: 8), arrivesAt: Date())
    let fade = store.sidebarFade
    store.dockedWindowProfile = workProfile
    store.dockedWindowTitle = "Work — Docs"
    store.confirmSwitchPreview(profile: switchedWork)
    check(store.switchPreview == nil && store.shownWindow?.window.id == 7, "a wrong guess changes to the window Safari reported")
    check(store.sidebarFade == fade, "without a second fade")
}

do {
    // A new window: Work had none. Safari shows it in front before Work's copy reports it.
    let store = storeWithoutCopies()
    send(store, copySnapshot("A", profile: nil, seq: 1, window: 1, title: "Mail", focused: true, at: 100))
    send(store, copyWindows("B", profile: workProfile, seq: 1, [], lastFocused: nil, at: 50))
    store.dockedWindowProfile = "default"
    store.beginSwitchPreview(id: 1, profile: switchedWork, guess: .placeholder, arrivesAt: Date())
    store.dockedWindowProfile = workProfile
    store.dockedWindowTitle = "Work — Start Page"
    store.confirmSwitchPreview(profile: switchedWork)
    check(store.switchPreview != nil && store.shownContent == .placeholder(switchedWork),
          "while the sidebar's own choice is still another profile's window, the placeholder stays: never another window's tabs")
    send(store, copyWindows("B", profile: workProfile, seq: 2, [(9, "Start Page")], lastFocused: 9, at: 300))
    check(store.switchPreview == nil && store.shownWindow?.instance == "B" && store.shownWindow?.window.id == 9,
          "once Work's copy reports the new window, the sidebar shows it")
}

do {
    // A newer click supersedes an older switch's guess; the sidebar can go back to following Safari.
    let store = storeWithoutCopies()
    send(store, copySnapshot("A", profile: nil, seq: 1, window: 1, title: "Mail", focused: true, at: 100))
    send(store, copyWindows("B", profile: workProfile, seq: 1, [(7, "Docs")], lastFocused: 7, at: 50))
    store.dockedWindowProfile = "default"
    let before = store.displayedContent
    store.beginSwitchPreview(id: 1, profile: switchedWork, guess: .window(instance: "B", windowId: 7), arrivesAt: Date())
    store.beginSwitchPreview(id: 2, profile: .defaultProfile, guess: .window(instance: "A", windowId: 1), arrivesAt: Date())
    store.refineSwitchPreview(id: 1, guess: .placeholder)
    check(store.switchPreview?.id == 2 && store.shownWindow?.instance == "A", "a newer click's guess replaces the older one, whose news is ignored")
    check(store.displayedContent == before && store.sidebarFade.phase == .out(SwitchPreviewRules.fadeOut),
          "while what was there before is still fading out, it carries on")
    wait(SwitchPreviewRules.fadeOut + 0.1)
    check(store.displayedContent == .window(store.shownWindow!), "and the newest guess comes in once it's out")
    store.confirmSwitchPreview(profile: switchedWork)
    check(store.switchPreview?.id == 2, "and so is a report of the older switch's profile")
    store.endSwitchPreview(because: "the switch didn't work")
    check(store.switchPreview == nil && store.shownWindow?.instance == "A", "a switch that didn't work: the sidebar follows Safari again")

    wait(0.5)
    check(store.sidebarFade.isOver && store.sidebarFade.opacity == 1 && store.displayedContent == store.shownContent,
          "the switch that didn't work ends its fade at full opacity, showing the window Safari has")

    // A newer switch while the new contents fade in, then the preview ending mid-fade-out.
    store.beginSwitchPreview(id: 4, profile: switchedWork, guess: .window(instance: "B", windowId: 7), arrivesAt: Date().addingTimeInterval(0.5))
    wait(SwitchPreviewRules.fadeOut + 0.1)
    check(store.displayedContent == .window(store.shownWindow!) && store.shownWindow?.instance == "B", "fading in Work's window")
    store.beginSwitchPreview(id: 5, profile: .defaultProfile, guess: .window(instance: "A", windowId: 1), arrivesAt: Date().addingTimeInterval(0.4))
    check(store.sidebarFade.showsOldContents && store.displayedContent == .window(TabStore.WindowSelection(instance: "B", window: store.liveSnapshots["B"]!.windows[0])),
          "a newer switch mid-fade-in fades out what's on screen")
    store.endSwitchPreview(because: "the switch didn't work")
    wait(1.2)
    check(store.sidebarFade.isOver && store.sidebarFade.opacity == 1 && store.displayedContent == store.shownContent && store.fadingOutContent == nil,
          "and when the preview ends mid-fade-out, the fade still ends at full opacity, showing what Safari has, once")

    // #41: a target its copy can't see shows its profile's lists and the tab bar list.
    store.beginSwitchPreview(id: 3, profile: switchedWork, guess: .unseen, arrivesAt: Date())
    check(store.shownContent == .unseen(profile: switchedWork) && store.shownProfile == switchedWork, "a window its copy can't see: its profile's lists, and the tab bar list")
}

try? FileManager.default.removeItem(at: stateFolder)

if failures == 0 {
    print("store checks passed")
} else {
    print("\(failures) store check(s) failed")
    exit(1)
}
