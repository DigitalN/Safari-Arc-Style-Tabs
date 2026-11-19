import Foundation

// Checks for when a tab's loading spinner shows (TabLoading.swift, #83): for the first 10 s of its loading, then
// only its dimmed favicon. Whether a hidden sidebar draws it needs the running app.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

var now: TimeInterval = 1000
func loadingClock() -> TabLoading {
    let loading = TabLoading()
    loading.now = { now }
    return loading
}

let tab = TabKey(instance: "copy", tabId: 1)
let other = TabKey(instance: "copy", tabId: 2)
let page = "https://camera.local/stream"

do {
    let loading = loadingClock()
    check(loading.spinnerTimeLeft(for: tab, loading: false, url: page) == nil, "a tab that isn't loading has no spinner")
    check(loading.spinnerTimeLeft(for: tab, loading: true, url: page) == TabLoading.spinnerFor,
          "a tab that starts loading shows its spinner for 10 s")
    now += 4
    check(loading.spinnerTimeLeft(for: tab, loading: true, url: page) == 6,
          "a row made again 4 s in (another window shown and this one again) has 6 s left, not 10")
    now += 6
    check(loading.spinnerTimeLeft(for: tab, loading: true, url: page) == nil,
          "10 s in, the spinner stops though the page is still loading")
    now += 3600
    check(loading.spinnerTimeLeft(for: tab, loading: true, url: page) == nil, "and doesn't come back an hour later")

    check(loading.spinnerTimeLeft(for: tab, loading: false, url: page) == nil, "the page finishes")
    check(loading.spinnerTimeLeft(for: tab, loading: true, url: page) == TabLoading.spinnerFor,
          "loading again gets a fresh 10 s")
    now += 12
    check(loading.spinnerTimeLeft(for: tab, loading: true, url: "https://camera.local/other") == TabLoading.spinnerFor,
          "so does loading another page without finishing first")

    check(loading.spinnerTimeLeft(for: other, loading: true, url: page) == TabLoading.spinnerFor,
          "each tab has its own time")
    now += 5
    check(loading.spinnerTimeLeft(for: tab, loading: true, url: "https://camera.local/other") == 5
          && loading.spinnerTimeLeft(for: other, loading: true, url: page) == 5,
          "and they run side by side")
}

do {
    // Tabs closed while loading are never seen finishing; the list doesn't grow without end.
    let loading = loadingClock()
    for id in 0..<(TabLoading.limit * 3) {
        _ = loading.spinnerTimeLeft(for: TabKey(instance: "copy", tabId: 100 + id), loading: true, url: page)
        now += 1
    }
    check(loading.spinnerTimeLeft(for: TabKey(instance: "copy", tabId: 100 + TabLoading.limit * 3 - 1), loading: true, url: page) == 9,
          "with many tabs loading, recent starts are kept")
}

if failures == 0 {
    print("tab loading checks passed")
} else {
    print("\(failures) tab loading check(s) failed")
    exit(1)
}
