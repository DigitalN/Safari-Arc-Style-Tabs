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

func snapshotObject(seq: Int, active: Int, tabs: [Int] = [1, 2, 3, 4]) -> [String: Any] {
    ["type": "snapshot", "instance": instance, "seq": seq, "focusedWindowId": 1, "lastFocusedWindowId": 1,
     "focusChangedAt": 1.0,
     "windows": [["id": 1, "focused": true, "incognito": false, "tabs": tabs.map { tab($0, active: $0 == active) }]]]
}

func send(_ store: TabStore, _ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    _ = store.handleMessage(type: object["type"] as! String, payload: data, object: object)
}

func activated(_ store: TabStore, tab id: Int, seq: Int? = nil) {
    var object: [String: Any] = ["type": "activated", "instance": instance, "windowId": 1, "tabId": id]
    if let seq { object["seq"] = seq }
    send(store, object)
}

func highlighted(_ store: TabStore) -> Int? {
    store.snapshots[instance]?.windows.first?.tabs.first(where: \.active)?.id
}

func makeStore(active: Int = 1) -> (TabStore, sent: () -> [[String: Any]]) {
    let store = TabStore()
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
    Thread.sleep(forTimeInterval: 1.1)
    activated(store, tab: 2)
    check(highlighted(store) == 2, "once the click is stale, Safari's report moves the highlight")
    activated(store, tab: 4)
    check(highlighted(store) == 4, "and the stale click doesn't hold back later reports")
}

do {
    // Stale pending is also dropped by a snapshot, so a late report isn't held back by it.
    let (store, _) = makeStore()
    click(store, tab: 3)
    Thread.sleep(forTimeInterval: 1.1)
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

if failures == 0 {
    print("store checks passed")
} else {
    print("\(failures) store check(s) failed")
    exit(1)
}
