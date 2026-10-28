import AppKit
import Observation

/// Favicons for tabs and bookmarks. Tries the icon URL the page declared, then the
/// site's /favicon.ico; views fall back to a letter tile when both fail.
///
/// Safari fetches the icons (background.js) and sends them over, so Side Tabs itself
/// never connects to websites. Tabs are often open on devices at home, like a router or
/// Home Assistant, and connecting to those from the app makes macOS ask for Local
/// Network access.
@Observable
final class FaviconStore {
    private(set) var images: [String: NSImage] = [:]
    /// Goes up when the extension is back after missing requests, so views ask again.
    private(set) var generation = 0

    /// Asks background.js to fetch these icon URLs and send them back.
    @ObservationIgnored var requestIcons: (([String]) -> Void)?

    private enum Outcome {
        case loaded, failed, unanswered
    }

    private struct Request {
        let id: Int
        var waiters: [CheckedContinuation<Outcome, Never>]
    }

    @ObservationIgnored private var requests: [String: Request] = [:]
    @ObservationIgnored private var nextRequestID = 0
    @ObservationIgnored private var queued: [String] = []
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private var missedAnswer = false
    @ObservationIgnored private var lastRetry = Date.distantPast

    /// Icon URLs to try for a page, best first.
    static func candidates(iconURL: String?, pageURL: String?) -> [String] {
        var result: [String] = []
        if let iconURL, !iconURL.isEmpty {
            result.append(iconURL)
        }
        if let pageURL, let url = URL(string: pageURL), let scheme = url.scheme, ["http", "https"].contains(scheme),
           let host = url.host() {
            let fallback = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/favicon.ico"
            if !result.contains(fallback) {
                result.append(fallback)
            }
        }
        return result
    }

    /// The first cached image among the candidates. Reading this in a view body keeps
    /// the view updated as icons arrive.
    func image(for candidates: [String]) -> NSImage? {
        for candidate in candidates {
            if let image = images[candidate] {
                return image
            }
        }
        return nil
    }

    func load(_ candidates: [String]) async {
        for candidate in candidates {
            if images[candidate] != nil {
                return
            }
            if let failed = failedAt[candidate], Date().timeIntervalSince(failed) < 600 {
                continue
            }
            switch await fetch(candidate) {
            case .loaded:
                return
            case .failed:
                continue
            case .unanswered:
                // Safari isn't running or the extension is off; try again once it's back.
                return
            }
        }
    }

    private func fetch(_ url: String) async -> Outcome {
        await withCheckedContinuation { continuation in
            if requests[url] != nil {
                requests[url]?.waiters.append(continuation)
                return
            }
            nextRequestID += 1
            let id = nextRequestID
            requests[url] = Request(id: id, waiters: [continuation])
            queued.append(url)
            if queued.count == 1 {
                // Views appear together; ask for all of their icons in one message.
                DispatchQueue.main.async { [weak self] in self?.sendQueued() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.requests[url]?.id == id else { return }
                self.missedAnswer = true
                self.finish(url, .unanswered)
            }
        }
    }

    private func sendQueued() {
        let urls = queued
        queued.removeAll()
        if !urls.isEmpty {
            requestIcons?(urls)
        }
    }

    /// An icon background.js fetched, or `nil` if it couldn't get one.
    func receive(url: String, data: Data?) {
        if let data, let image = NSImage(data: data), image.isValid, image.size.width > 0 {
            images[url] = image
            failedAt[url] = nil
            finish(url, .loaded)
        } else {
            failedAt[url] = Date()
            finish(url, .failed)
        }
    }

    /// Called for every message from the extension. If requests went unanswered before it
    /// got here (Safari opened after Side Tabs, or the extension was turned on), ask again.
    /// At most once a minute, in case an older background.js is still running and ignores them.
    func extensionIsReachable() {
        guard missedAnswer, Date().timeIntervalSince(lastRetry) > 60 else { return }
        missedAnswer = false
        lastRetry = Date()
        generation += 1
    }

    private func finish(_ url: String, _ outcome: Outcome) {
        guard let request = requests.removeValue(forKey: url) else { return }
        request.waiters.forEach { $0.resume(returning: outcome) }
    }
}
