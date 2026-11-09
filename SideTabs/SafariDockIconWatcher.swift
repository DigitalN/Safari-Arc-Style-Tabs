@preconcurrency import ApplicationServices
import AppKit
import os

// Noticing a click on Safari's own icon in the Dock (#42).
//
// With "Minimize other profiles' windows" on, once the current profile's last window closes, a click
// on Safari's Dock icon makes macOS bring back the window minimized most recently, which belongs to
// another profile. The core arms this watcher in that state, hears about the click, and opens a
// window in the current profile instead. The watcher only notices the click: macOS handles it as usual.
//
// The rules are kept apart from AppKit and Accessibility in DockIconRules, so they can be checked
// against constructed Dock trees (Tests/DockIconChecks) without the Dock:
// - which of the Dock's items is Safari's: the app item whose AXURL is Safari's bundle, never by title
//   (translated) and never a minimized window's tile, a folder or another app
// - whether a press was a plain click on it: started and ended on the icon, short enough that the
//   Dock didn't open the icon's menu, barely moved, without Command or Control, and confirmed by the
//   Dock in time

/// One element of the Dock's Accessibility tree, as far as finding Safari's item needs to know it.
/// The real ones read their attributes from the Dock (DockItemReader); the checks use constructed ones.
nonisolated protocol DockNode {
    var role: String? { get }
    var subrole: String? { get }
    /// `AXURL`. On an app's item it's the app's bundle, which isn't translated (the item's title is).
    var url: URL? { get }
    /// Reading the children costs a round trip to the Dock, so the search reads only where it must.
    func children() -> [Self]
}

/// What the Dock said about Safari's item at the moment of a mouse-down or mouse-up.
nonisolated struct DockSample: Equatable {
    /// Safari's item's frame, in Accessibility's screen coordinates: origin at the top left of the
    /// main display, y down, across every display. Usually one.
    var frames: [CGRect]
    /// The item's menu is showing (the icon was held, Control-clicked or right-clicked).
    var menuOpen: Bool
    /// The Dock's own answer to "is Safari's item under this point?", asked only near the item.
    /// Nil when it wasn't asked.
    var dockSaysOnItem: Bool?
}

/// Where a press's mouse-down or mouse-up was, as far as Safari's Dock icon goes.
nonisolated enum DockHit: Equatable {
    case onIcon
    case elsewhere
    /// Safari's icon's menu was showing: a press now is a choice in it, or closes it.
    case menuOpen
    /// The Dock didn't answer in time, or Safari's item couldn't be found.
    case noAnswer
}

/// A press of the left mouse button, from mouse-down to mouse-up.
nonisolated struct DockPress: Equatable {
    /// In Accessibility's screen coordinates, like DockSample.frames.
    var downPoint: CGPoint
    /// The events' own timestamps (NSEvent.timestamp), so the length of the press doesn't depend on
    /// how soon the watcher heard about it.
    var downTime: TimeInterval
    var upPoint: CGPoint
    var upTime: TimeInterval
    /// When the watcher heard about the mouse-up, on ProcessInfo.systemUptime's clock: what the
    /// deadline for reporting the click is measured from.
    var upSeenAt: TimeInterval
    /// The farthest the mouse got from `downPoint` during the press, the mouse-up included.
    var farthest: CGFloat
    var withCommand: Bool
    var withControl: Bool
}

/// Why a press wasn't counted as a click on Safari's Dock icon. Logged, so a live test can tell.
nonisolated enum DockClickRefusal: String {
    case startedElsewhere = "it started off Safari's icon"
    case endedElsewhere = "it ended off Safari's icon"
    case menuOpen = "the icon's menu was showing"
    case noAnswer = "the Dock didn't answer in time"
    case heldTooLong = "it was held long enough for the icon's menu"
    case moved = "the mouse moved"
    case withModifier = "Command or Control was held"
    case late = "the Dock answered too late"
}

nonisolated enum DockIconRules {
    static let dockBundleID = "com.apple.dock"
    /// Safari's bundle identifier, as SafariTracker.safariBundleID. Matched exactly: Safari
    /// Technology Preview (`com.apple.SafariTechnologyPreview`) and web apps added to the Dock from
    /// Safari (`com.apple.Safari.WebApp.…`) aren't Safari.
    static let safariBundleID = "com.apple.Safari"

    static let itemRole = "AXDockItem"
    /// An app's own icon. A minimized window's tile is `AXMinimizedWindowDockItem` and may point at
    /// its app too; folders, documents, separators and the Trash have subroles of their own.
    static let applicationSubrole = "AXApplicationDockItem"
    static let menuRole = "AXMenu"

    // MARK: - Finding Safari's item

    /// How many levels below the Dock the search goes. The items are two levels down (Dock → list →
    /// item); one more allows for a wrapper nobody has seen yet.
    static let searchDepth = 3
    /// The search stops opening containers once it has read this many elements: a Dock has a few
    /// dozen items, and anything far bigger isn't the Dock's list.
    static let searchLimit = 400

    /// Safari's items in the Dock's tree: usually one. Looks level by level and never opens an item,
    /// whose only children are its menu.
    static func safariItems<Node: DockNode>(in dock: Node, isSafari: (URL) -> Bool) -> [Node] {
        var found: [Node] = []
        var level = dock.children()
        var read = level.count
        var depth = 1
        while !level.isEmpty {
            var next: [Node] = []
            for node in level {
                if node.role == itemRole {
                    if isSafariItem(role: node.role, subrole: node.subrole, url: node.url, isSafari: isSafari) {
                        found.append(node)
                    }
                } else if depth < searchDepth, read < searchLimit {
                    let children = node.children()
                    read += children.count
                    next += children
                }
            }
            level = next
            depth += 1
        }
        return found
    }

    /// Whether an element with these attributes is Safari's icon. The title plays no part.
    static func isSafariItem(role: String?, subrole: String?, url: URL?, isSafari: (URL) -> Bool) -> Bool {
        guard role == itemRole, subrole == applicationSubrole, let url else { return false }
        return isSafari(url)
    }

    /// Whether `url` is Safari's bundle: one of the paths Safari is known at (where it runs from,
    /// and where Launch Services has it), or, written another way (`/Applications/Safari.app` is a
    /// link to the copy in the system's cryptex), a bundle whose identifier is Safari's.
    static func isSafariBundle(_ url: URL, knownPaths: Set<String>, bundleIdentifier: (URL) -> String?) -> Bool {
        guard let path = bundlePath(url) else { return false }
        if knownPaths.contains(path) { return true }
        return bundleIdentifier(url) == safariBundleID
    }

    /// A file URL's path written one way: standardized, decoded, no trailing slash. Nil for anything
    /// that isn't a file (a web link's item).
    static func bundlePath(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? nil : path
    }

    /// Whether the item shows its menu: the Dock puts the menu under the item while it's open.
    static func showsMenu<Node: DockNode>(_ item: Node) -> Bool {
        item.children().contains { $0.role == menuRole }
    }

    // MARK: - Where a press was

    /// How far around Safari's frame the Dock itself is also asked what's under a point. With
    /// magnification the icon under the mouse grows, up to 128 points, and it isn't known yet whether
    /// Accessibility gives the grown frame; the Dock's own hit test settles it near the icon.
    static let askRadius: CGFloat = 128

    /// Inclusive of the frame's edges. A frame with no area contains nothing.
    static func contains(_ frame: CGRect, _ point: CGPoint) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        return point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    /// Whether to ask the Dock what's under `point`: on or near one of Safari's frames. Far from
    /// them, the frames say enough, and the Dock isn't asked about every click on the screen.
    static func isNear(_ point: CGPoint, frames: [CGRect]) -> Bool {
        frames.contains { contains($0.insetBy(dx: -askRadius, dy: -askRadius), point) }
    }

    /// Where the mouse was, from what the Dock said at that moment: on the icon when the point is in
    /// its frame or the Dock says the item is under it.
    static func hit(_ point: CGPoint, sample: DockSample?) -> DockHit {
        guard let sample, !sample.frames.isEmpty else { return .noAnswer }
        if sample.menuOpen { return .menuOpen }
        if sample.frames.contains(where: { contains($0, point) }) || sample.dockSaysOnItem == true {
            return .onIcon
        }
        return .elsewhere
    }

    /// A point in AppKit's screen coordinates (origin at the bottom left of the main display, y up)
    /// in Accessibility's. `primaryScreenHeight` is the height of the display with the menu bar,
    /// `NSScreen.screens[0]`, whatever display the point is on.
    static func quartzPoint(cocoa point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    // MARK: - Whether a press was a click

    /// The Dock's menu delay when nobody has changed it: a press on an icon held this long opens the
    /// icon's menu instead of clicking it. Read from the Dock itself: it takes `popup-delay` from its
    /// preferences, with 0.5 s as the default and for any value that isn't above zero.
    static let defaultMenuDelay: TimeInterval = 0.5

    /// The Dock's menu delay, from its `popup-delay` preference if there is one.
    static func menuDelay(preference: Double?) -> TimeInterval {
        guard let preference, preference > 0 else { return defaultMenuDelay }
        return preference
    }

    /// The longest press that counts: a fifth under the menu delay, 0.4 s with the Dock's default.
    /// The Dock's timer starts when it handles the mouse-down, a little after the event, so a press
    /// right at the delay might have opened the menu, and a choice in that menu must never count.
    /// Ordinary clicks last about a tenth of a second. Never more than a second, whatever the
    /// preference says.
    static func longestClick(menuDelay: TimeInterval) -> TimeInterval {
        min(menuDelay * 0.8, 1)
    }

    /// How far the mouse may move during a click, in points. A click wobbles by a point or two; a
    /// press that moves further is the start of a drag (taking the icon out of the Dock, or moving it
    /// along), which the Dock doesn't count as a click. Small next to the smallest icon (16 points).
    static let farthestMove: CGFloat = 6

    /// How long after the mouse-up a click may still be reported. The core waits about a second for
    /// the window macOS brings back, so a click the Dock was slow to confirm is dropped.
    static let latestReport: TimeInterval = 0.5

    /// What's wrong with the press itself, before asking the Dock about its mouse-up.
    static func pressRefusal(_ press: DockPress, menuDelay: TimeInterval) -> DockClickRefusal? {
        let held = press.upTime - press.downTime
        if press.withCommand || press.withControl { return .withModifier }
        if held < 0 || held >= longestClick(menuDelay: menuDelay) { return .heldTooLong }
        if press.farthest > farthestMove { return .moved }
        return nil
    }

    /// Why the press isn't a plain click on Safari's Dock icon, or nil when it is. `up` is nil when
    /// the Dock wasn't asked about the mouse-up (the press was refused already). `now` is on
    /// ProcessInfo.systemUptime's clock.
    static func refusal(_ press: DockPress, down: DockHit, up: DockHit?, menuDelay: TimeInterval,
                        now: TimeInterval) -> DockClickRefusal? {
        switch down {
        case .onIcon: break
        case .elsewhere: return .startedElsewhere
        case .menuOpen: return .menuOpen
        case .noAnswer: return .noAnswer
        }
        if let refusal = pressRefusal(press, menuDelay: menuDelay) { return refusal }
        switch up {
        case .onIcon: break
        case .elsewhere: return .endedElsewhere
        case .menuOpen: return .menuOpen
        case .noAnswer, nil: return .noAnswer
        }
        if now - press.upSeenAt > latestReport { return .late }
        return nil
    }

    static func isClick(_ press: DockPress, down: DockHit, up: DockHit?, menuDelay: TimeInterval, now: TimeInterval) -> Bool {
        refusal(press, down: down, up: up, menuDelay: menuDelay, now: now) == nil
    }
}

// MARK: - The watcher

/// Watches for a plain click on Safari's own icon in the Dock, while armed.
///
/// `arm()` installs a global mouse monitor (mouse events only, never keys) and `disarm()` removes it.
/// Each press is checked against Safari's item, read through the Dock's Accessibility on a queue of
/// its own at the mouse-down and the mouse-up, so the frame is wherever the Dock is at that moment
/// (any side, any display, shown after hiding, magnified). The main thread never waits for the Dock.
@MainActor
final class SafariDockIconWatcher {
    /// Called on the main thread after a plain click on Safari's Dock icon: a few milliseconds after
    /// the mouse-up usually, never more than DockIconRules.latestReport, and never after `disarm()`.
    /// macOS may bring a window back before or after this arrives. A double-click calls it twice.
    var onClick: (() -> Void)?

    private var monitor: Any?
    /// Moves on with every arm and disarm, so a click confirmed for an earlier arming isn't reported.
    private var generation = 0
    private var press: Press?
    private var lastPressID: UInt64 = 0
    private let dock = DockItemReader()
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "profiles")

    private struct Press {
        let id: UInt64
        let point: CGPoint
        let time: TimeInterval
        let withCommand: Bool
        let withControl: Bool
        var farthest: CGFloat = 0
    }

    init() {}

    isolated deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Starts listening. Calling it again while armed does nothing.
    func arm() {
        guard monitor == nil else { return }
        generation += 1
        let generation = generation
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event, generation: generation)
            }
        }
        dock.prepare()
        log.info("watching for a click on Safari's Dock icon")
    }

    /// Stops listening and removes the monitor. Calling it while not armed does nothing.
    func disarm() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        generation += 1
        press = nil
        dock.forgetPress()
        log.info("stopped watching Safari's Dock icon")
    }

    private func handle(_ event: NSEvent, generation: Int) {
        guard generation == self.generation else { return }
        let point = Self.screenPoint(of: event)
        switch event.type {
        case .leftMouseDown:
            lastPressID += 1
            let flags = event.modifierFlags
            press = Press(id: lastPressID, point: point, time: event.timestamp,
                          withCommand: flags.contains(.command), withControl: flags.contains(.control))
            dock.pressBegan(lastPressID, at: point)
        case .leftMouseDragged:
            if let start = press {
                press?.farthest = max(start.farthest, Self.distance(start.point, point))
            }
        case .leftMouseUp:
            guard let start = press else { return }
            press = nil
            let flags = event.modifierFlags
            let finished = DockPress(
                downPoint: start.point, downTime: start.time, upPoint: point, upTime: event.timestamp,
                upSeenAt: ProcessInfo.processInfo.systemUptime,
                farthest: max(start.farthest, Self.distance(start.point, point)),
                withCommand: start.withCommand || flags.contains(.command),
                withControl: start.withControl || flags.contains(.control))
            dock.pressEnded(start.id, finished) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.clicked(generation: generation)
                    }
                }
            }
        default:
            break
        }
    }

    private func clicked(generation: Int) {
        guard monitor != nil, generation == self.generation else { return }
        onClick?()
    }

    /// Where the event happened, in Accessibility's screen coordinates.
    private static func screenPoint(of event: NSEvent) -> CGPoint {
        if let location = event.cgEvent?.location {
            return location
        }
        // A global monitor's event has no window, so its location is on the screen, in AppKit's coordinates.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return DockIconRules.quartzPoint(cocoa: event.locationInWindow, primaryScreenHeight: primaryHeight)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}

// MARK: - Reading the Dock

/// Reads Safari's item from the Dock's Accessibility, on a queue of its own: the Dock can be slow or
/// not answer, and nothing here may hold up the main thread or Safari's queues. When the Dock doesn't
/// answer in time, the press isn't counted.
///
/// Safari's item is found once (a search reads every item in the Dock) and kept. Its frame and menu
/// are read again at every mouse-down and mouse-up, in one round trip, so they're never out of date;
/// when the kept item has gone (the Dock restarted) it's looked for again.
nonisolated final class DockItemReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.digitaln.sidetabs.accessibility-dock", qos: .userInteractive)
    /// How long one Accessibility call to the Dock may take.
    private static let timeout: TimeInterval = 0.15
    /// After a search that found nothing, how long before searching again.
    private static let searchRetry: TimeInterval = 1
    private let query = AXQuery(timeout: timeout)
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "profiles")

    // Only used on `queue`.
    private var dock: AXUIElement?
    private var dockProcess: pid_t = 0
    private var items: [AXUIElement] = []
    private var knownSafariPaths: Set<String> = []
    /// Bundle identifiers read from the Dock's apps, by URL; "" for a bundle without one.
    private var bundleIdentifiers: [String: String] = [:]
    private var menuDelay = DockIconRules.defaultMenuDelay
    private var lastFailedSearch: TimeInterval = -.infinity
    private var down: (id: UInt64, hit: DockHit, detail: String)?

    /// Gets ready for clicks: the Dock's menu delay, where Safari is, and Safari's item if it isn't
    /// known yet, so the first click doesn't wait for a search.
    func prepare() {
        queue.async { [self] in
            menuDelay = DockIconRules.menuDelay(preference: Self.menuDelayPreference())
            knownSafariPaths = Self.safariPaths()
            down = nil
            lastFailedSearch = -.infinity
            if items.isEmpty {
                search()
            }
        }
    }

    func forgetPress() {
        queue.async { [self] in
            down = nil
        }
    }

    func pressBegan(_ id: UInt64, at point: CGPoint) {
        queue.async { [self] in
            let sample = sample(at: point)
            down = (id, DockIconRules.hit(point, sample: sample), Self.describe(sample, at: point))
        }
    }

    /// Decides whether the press was a click on Safari's icon, and calls `report` on this queue if so.
    func pressEnded(_ id: UInt64, _ press: DockPress, then report: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard let down, down.id == id else { return }
            self.down = nil
            // A press anywhere else on the screen: nothing to say. A Dock that didn't answer said so already.
            guard down.hit == .onIcon || down.hit == .menuOpen else { return }
            let held = Int(((press.upTime - press.downTime) * 1000).rounded())
            let moved = Int(press.farthest.rounded())
            var up: DockHit?
            var upDetail = "not read"
            if down.hit == .onIcon, DockIconRules.pressRefusal(press, menuDelay: menuDelay) == nil {
                let sample = sample(at: press.upPoint)
                up = DockIconRules.hit(press.upPoint, sample: sample)
                upDetail = Self.describe(sample, at: press.upPoint)
            }
            let now = ProcessInfo.processInfo.systemUptime
            let after = Int(((now - press.upSeenAt) * 1000).rounded())
            let details = "held \(held) ms, moved \(moved) pt; down: \(down.detail); up: \(upDetail); \(after) ms after release"
            if let refusal = DockIconRules.refusal(press, down: down.hit, up: up, menuDelay: menuDelay, now: now) {
                log.info("a press on Safari's Dock icon isn't a click: \(refusal.rawValue, privacy: .public) (\(details, privacy: .public))")
            } else {
                log.notice("click on Safari's Dock icon (\(details, privacy: .public))")
                report()
            }
        }
    }

    /// For the log: what the frames and the Dock said about the point. No names, titles or URLs.
    private static func describe(_ sample: DockSample?, at point: CGPoint) -> String {
        guard let sample else { return "no answer" }
        if sample.menuOpen { return "menu showing" }
        let inFrame = sample.frames.contains { DockIconRules.contains($0, point) }
        let dockSays = sample.dockSaysOnItem.map { $0 ? "yes" : "no" } ?? "not asked"
        return "in frame \(inFrame ? "yes" : "no"), Dock says \(dockSays)"
    }

    // MARK: Reading

    /// What the Dock says about Safari's item now, for a press at `point`. Nil when the Dock didn't
    /// answer in time or Safari's item can't be found.
    private func sample(at point: CGPoint) -> DockSample? {
        for _ in 0..<2 {
            if items.isEmpty, !search() {
                return nil
            }
            query.clearTimedOut()
            var frames: [CGRect] = []
            var menuOpen = false
            var gone = false
            for item in items {
                guard let reading = read(item) else {
                    if query.timedOut {
                        log.info("the Dock didn't answer in time")
                        return nil
                    }
                    gone = true
                    break
                }
                frames.append(reading.frame)
                menuOpen = menuOpen || reading.menuOpen
            }
            if gone {
                // The Dock restarted, or the item isn't Safari's any more: look again, once.
                items = []
                continue
            }
            var sample = DockSample(frames: frames, menuOpen: menuOpen, dockSaysOnItem: nil)
            if !menuOpen, DockIconRules.isNear(point, frames: frames) {
                guard let says = isItem(at: point) else {
                    log.info("the Dock didn't answer in time")
                    return nil
                }
                sample.dockSaysOnItem = says
            }
            return sample
        }
        return nil
    }

    /// The item's frame and whether its menu shows, in one round trip, checking on the way that it's
    /// still Safari's icon. Nil when it couldn't be read (see `query.timedOut`) or isn't Safari's.
    private func read(_ item: AXUIElement) -> (frame: CGRect, menuOpen: Bool)? {
        let attributes = [kAXPositionAttribute, kAXSizeAttribute, kAXRoleAttribute, kAXSubroleAttribute,
                          kAXURLAttribute, kAXShownMenuUIElementAttribute, kAXChildrenAttribute]
        guard let values = query.copyMultiple(item, attributes) else { return nil }
        guard DockIconRules.isSafariItem(role: values[2] as? String, subrole: values[3] as? String,
                                         url: Self.url(values[4]), isSafari: isSafari),
              let positionValue = values[0], CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = values[1], CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        // The menu shows under the item while it's open. Items have no other children, so this
        // usually reads nothing more.
        let children = (values[6] as? [AXUIElement]) ?? []
        let shownMenu = values[5].map { CFGetTypeID($0) == AXUIElementGetTypeID() } ?? false
        let menuOpen = shownMenu || children.contains { query.string($0, kAXRoleAttribute) == DockIconRules.menuRole }
        return (CGRect(origin: position, size: size), menuOpen)
    }

    /// The Dock's own hit test: whether Safari's item is what's under `point`. Nil when the Dock
    /// didn't answer in time.
    private func isItem(at point: CGPoint) -> Bool? {
        guard let dock else { return false }
        AXUIElementSetMessagingTimeout(dock, Float(Self.timeout))
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &element)
        if error == .cannotComplete { return nil }
        guard error == .success, let element else { return false }
        return items.contains { CFEqual($0, element) }
    }

    /// Looks for Safari's item in the Dock's tree. False when it can't be found (the Dock didn't
    /// answer, or has no item for Safari); not tried again for a second after that.
    @discardableResult
    private func search() -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        guard start - lastFailedSearch >= Self.searchRetry else { return false }
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: DockIconRules.dockBundleID)
            .first?.processIdentifier else {
            lastFailedSearch = start
            log.info("the Dock isn't running")
            return false
        }
        if process != dockProcess || dock == nil {
            dock = AXUIElementCreateApplication(process)
            dockProcess = process
        }
        guard let dock else { return false }
        if knownSafariPaths.isEmpty {
            knownSafariPaths = Self.safariPaths()
        }
        query.clearTimedOut()
        let found = DockIconRules.safariItems(in: LiveDockNode(element: dock, query: query), isSafari: isSafari)
        let milliseconds = Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
        guard !found.isEmpty else {
            items = []
            lastFailedSearch = start
            log.info("Safari's Dock icon not found (\(self.query.timedOut ? "the Dock didn't answer in time" : "no item for Safari", privacy: .public), \(milliseconds) ms)")
            return false
        }
        items = found.map(\.element)
        log.info("found Safari's Dock icon in \(milliseconds) ms (\(found.count) item(s))")
        return true
    }

    private func isSafari(_ url: URL) -> Bool {
        DockIconRules.isSafariBundle(url, knownPaths: knownSafariPaths, bundleIdentifier: bundleIdentifier(for:))
    }

    private func bundleIdentifier(for url: URL) -> String? {
        let key = url.absoluteString
        if let known = bundleIdentifiers[key] {
            return known.isEmpty ? nil : known
        }
        let identifier = Bundle(url: url)?.bundleIdentifier
        bundleIdentifiers[key] = identifier ?? ""
        return identifier
    }

    /// Where Safari is: where it runs from and where Launch Services has it (the system's cryptex,
    /// on macOS 26), and `/Applications/Safari.app`, the link to it, each also with links resolved.
    private static func safariPaths() -> Set<String> {
        var urls = [URL(fileURLWithPath: "/Applications/Safari.app")]
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: DockIconRules.safariBundleID).first?.bundleURL {
            urls.append(running)
        }
        if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DockIconRules.safariBundleID) {
            urls.append(installed)
        }
        return Set(urls.flatMap { [$0, $0.resolvingSymlinksInPath()] }.compactMap(DockIconRules.bundlePath))
    }

    /// The Dock's `popup-delay` preference, if it's set. Side Tabs isn't sandboxed, so it can read
    /// the Dock's preferences; it never changes them.
    private static func menuDelayPreference() -> Double? {
        let value = CFPreferencesCopyAppValue("popup-delay" as CFString, DockIconRules.dockBundleID as CFString)
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    fileprivate static func url(_ value: CFTypeRef?) -> URL? {
        if let url = value as? URL { return url }
        if let text = value as? String { return URL(string: text) }
        return nil
    }
}

/// An element of the Dock's tree, read through Accessibility: its role, subrole and URL in one round
/// trip. Once a call has timed out, reads nothing more, so a Dock that doesn't answer costs one timeout,
/// not one per item.
nonisolated private struct LiveDockNode: DockNode {
    let element: AXUIElement
    let query: AXQuery
    let role: String?
    let subrole: String?
    let url: URL?

    init(element: AXUIElement, query: AXQuery) {
        self.element = element
        self.query = query
        let values = query.timedOut ? nil : query.copyMultiple(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXURLAttribute])
        role = values?[0] as? String
        subrole = values?[1] as? String
        url = DockItemReader.url(values?[2] ?? nil)
    }

    func children() -> [LiveDockNode] {
        guard !query.timedOut else { return [] }
        return query.elements(element, kAXChildrenAttribute).map { LiveDockNode(element: $0, query: query) }
    }
}
