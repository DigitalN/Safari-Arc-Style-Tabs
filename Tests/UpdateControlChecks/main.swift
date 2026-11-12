import Foundation

// Checks for what Check for Updates… shows in each of the updater's states (UpdateControl.swift, #70).
// The menu bar menu and Settings → General both show it. What a click does is Updater.checkNow(), which
// needs the running app; these cover the titles and which states can be clicked.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

// MARK: - Each state

let idle = UpdateControl(.idle)
check(idle.title == "Check for Updates…", "idle: Check for Updates…, with an ellipsis, not three dots")
check(idle.isButton, "idle: a button that checks now (or opens the releases page for a copy that can't update itself)")

let checking = UpdateControl(.checking)
check(checking.title == "Checking for Updates…", "checking: Checking for Updates…")
check(!checking.isButton, "checking: not clickable")

let downloading = UpdateControl(.downloading(version: "1.4"))
check(downloading.title == "Downloading Side Tabs 1.4…", "downloading: names the version being downloaded")
check(!downloading.isButton, "downloading: not clickable")

let ready = UpdateControl(.ready(version: "1.4"))
check(ready.title == "Restart to Update to 1.4", "ready: names the version it restarts into, with no ellipsis")
check(ready.isButton, "ready: a button that restarts into the update")

// MARK: - Versions

check(UpdateControl(.downloading(version: "1.10.2")).title == "Downloading Side Tabs 1.10.2…",
      "a dotted version is shown as the release's tag gives it")
check(UpdateControl(.ready(version: "1.10.2")).title == "Restart to Update to 1.10.2",
      "and the same when it's ready")
check(UpdateControl(.ready(version: "1.4")) != UpdateControl(.ready(version: "1.5")),
      "a newer version that's ready changes the control")

// MARK: - All four states differ

let titles = [idle, checking, downloading, ready].map(\.title)
check(Set(titles).count == titles.count, "each state has its own title")

if failures > 0 {
    print("\(failures) update control check(s) failed")
    exit(1)
}
print("update control checks passed")
