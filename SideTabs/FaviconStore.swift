import AppKit
import ImageIO
import Observation

/// One icon URL's image. Each is observed on its own, so an icon arriving updates only the views that show
/// it, not every row (#83).
final class FaviconBox: Observable {
    private let registrar = ObservationRegistrar()
    private var stored: CGImage?

    /// Reading this in a view body keeps the view updated as the icon arrives or goes.
    var image: CGImage? {
        registrar.access(self, keyPath: \.image)
        return stored
    }

    /// Always tells the views reading it, even when it was nil already: a box that's dropped from the store
    /// sends them back to it for a new one.
    fileprivate func set(_ image: CGImage?) {
        registrar.withMutation(of: self, keyPath: \.image) {
            stored = image
        }
    }

    fileprivate var peek: CGImage? { stored }
    /// How many views show this icon now (`FaviconStore.show`). A box that's shown is never dropped.
    fileprivate var holders = 0
    /// When it was last read or shown, in `FaviconStore`'s own count, for dropping the least recently used.
    fileprivate var lastUsed = 0
}

/// Favicons for tabs and bookmarks. Tries the icon URL the page declared, then the
/// site's /favicon.ico; views fall back to a letter tile when both fail.
///
/// Safari fetches the icons (background.js) and sends them over, so Side Tabs itself
/// never connects to websites. Tabs are often open on devices at home, like a router or
/// Home Assistant, and connecting to those from the app makes macOS ask for Local
/// Network access.
///
/// Icons are kept at `pixelSize`, whatever size they came in, and only so many that no view shows are kept
/// (`unshownLimit`), the least recently used going first (#83).
@Observable
final class FaviconStore {
    /// The most pixels an icon is kept at, across: the largest any view draws one, the favorites' 20 pt tiles, on a
    /// Retina display. Row icons are 16 pt, 32 px.
    nonisolated static let pixelSize = 40
    /// How many icons no view shows are kept: other windows' and profiles' tabs, closed tabs, bookmarks in closed
    /// folders. At `pixelSize` each is under 7 KB.
    nonisolated static let unshownLimit = 200

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
    /// An icon URL that failed isn't asked for again for this long.
    nonisolated private static let retryFailedAfter: TimeInterval = 600

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

    /// The first cached image among the candidates. Reading this in a view body keeps the view updated as
    /// those icons arrive, and only those.
    func image(for candidates: [String]) -> CGImage? {
        for candidate in candidates {
            let box = box(for: candidate)
            use(box)
            if let image = box.image {
                return image
            }
        }
        return nil
    }

    /// For as long as a view shows these candidates: fetches the first one that loads, and keeps their icons
    /// from being dropped. Returns when the task it runs in is cancelled (the view goes, or shows others).
    func show(_ candidates: [String]) async {
        let boxes = candidates.map(box(for:))
        for box in boxes {
            box.holders += 1
            use(box)
        }
        defer {
            for box in boxes {
                box.holders -= 1
                use(box)
            }
            trimIfNeeded()
        }
        await load(candidates)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(86_400))
        }
    }

    private func load(_ candidates: [String]) async {
        for candidate in candidates {
            if boxes[candidate]?.peek != nil {
                return
            }
            if let failed = failedAt[candidate], Date().timeIntervalSince(failed) < Self.retryFailedAfter {
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
        if let data, let image = Self.downsample(data) {
            let box = box(for: url)
            box.set(image)
            use(box)
            failedAt[url] = nil
            finish(url, .loaded)
            trimIfNeeded()
        } else {
            failedAt[url] = Date()
            finish(url, .failed)
        }
    }

    // MARK: - The icons kept

    @ObservationIgnored private var boxes: [String: FaviconBox] = [:]
    @ObservationIgnored private var uses = 0
    @ObservationIgnored private var trimScheduled = false

    /// How many icon URLs have a box: shown, kept, or asked for. For the checks in Tests/.
    var keptCount: Int { boxes.count }

    /// The URL's box, made if there's none. Views read it in their bodies, so a box is never replaced while it's
    /// kept; a dropped one tells its views (`FaviconBox.set`), and they come back for a new one.
    private func box(for url: String) -> FaviconBox {
        if let box = boxes[url] {
            return box
        }
        let box = FaviconBox()
        boxes[url] = box
        if boxes.count > Self.unshownLimit, !trimScheduled {
            // Not from inside a view body, where this is called: dropping a box updates views.
            trimScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.trimScheduled = false
                self?.trimIfNeeded()
            }
        }
        return box
    }

    private func use(_ box: FaviconBox) {
        uses += 1
        box.lastUsed = uses
    }

    /// Drops the least recently used icons no view shows, past `unshownLimit`, and failures old enough to try again.
    private func trimIfNeeded() {
        guard boxes.count > Self.unshownLimit else { return }
        let unshown = boxes.filter { $0.value.holders == 0 }
        if unshown.count > Self.unshownLimit {
            for (url, box) in unshown.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(unshown.count - Self.unshownLimit) {
                boxes[url] = nil
                box.set(nil)
            }
        }
        let now = Date()
        failedAt = failedAt.filter { now.timeIntervalSince($0.value) < Self.retryFailedAfter }
    }

    // MARK: - Downsampling

    /// An icon at `pixelSize` at most, decoded once here instead of at its full size each time it's drawn. Icons
    /// come in at up to 512 px (touch icons, ICOs with every size); from an ICO, the smallest size that's at least
    /// `pixelSize` is used. SVGs and anything else ImageIO doesn't read go through NSImage.
    nonisolated static func downsample(_ data: Data) -> CGImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, bestIndex(in: source), options as CFDictionary),
               image.width > 0, image.height > 0 {
                return image
            }
        }
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        return render(image)
    }

    /// The image in the file to downsample: the smallest at least `pixelSize` across, or else the largest.
    nonisolated private static func bestIndex(in source: CGImageSource) -> Int {
        let sizes = (0..<CGImageSourceGetCount(source)).map { index -> Int in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            return max(width, height)
        }
        let largeEnough = sizes.indices.filter { sizes[$0] >= pixelSize }
        if let smallest = largeEnough.min(by: { sizes[$0] < sizes[$1] }) {
            return smallest
        }
        return sizes.indices.max(by: { sizes[$0] < sizes[$1] }) ?? 0
    }

    /// Draws an image NSImage can read into a bitmap `pixelSize` across, keeping its shape.
    nonisolated private static func render(_ image: NSImage) -> CGImage? {
        let scale = CGFloat(pixelSize) / max(image.size.width, image.size.height)
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = previous
        return context.makeImage()
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
