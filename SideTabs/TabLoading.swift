import Foundation

/// When a tab's loading spinner shows: for the first `spinnerFor` seconds of its loading, then only its dimmed
/// favicon. Some pages never finish loading (a camera's MJPEG stream, a page that long-polls), and a spinner
/// redraws the sidebar at the display's rate for as long as it shows (#83).
///
/// Kept apart from the rows, which come and go (another window shown and this one again, a tab moving under a
/// favorite), so a row made again for a tab that's still loading doesn't start its spinner over.
final class TabLoading {
    static let spinnerFor: TimeInterval = 10
    /// More starts than this, and the ones whose spinners are over are forgotten. A row that sees its tab still
    /// loading afterwards starts again, which only happens with this many tabs loading at once.
    static let limit = 200

    private struct Start {
        let at: TimeInterval
        let url: String?
    }

    private var starts: [TabKey: Start] = [:]
    /// The Mac's awake time. Only the checks in Tests/ pass anything else.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// How much longer the tab's spinner shows, or nil once it doesn't. Called with what the tab's row shows each
    /// time that changes. Its time starts when it's first seen loading, and again when it's seen loading after
    /// being seen not loading, or loading another page.
    func spinnerTimeLeft(for key: TabKey, loading: Bool, url: String?) -> TimeInterval? {
        guard loading else {
            starts[key] = nil
            return nil
        }
        let now = now()
        let start: Start
        if let known = starts[key], known.url == url {
            start = known
        } else {
            start = Start(at: now, url: url)
            starts[key] = start
            forgetFinishedIfNeeded(now: now)
        }
        let left = Self.spinnerFor - (now - start.at)
        return left > 0 ? left : nil
    }

    private func forgetFinishedIfNeeded(now: TimeInterval) {
        guard starts.count > Self.limit else { return }
        starts = starts.filter { now - $0.value.at < Self.spinnerFor }
    }
}
