import AppKit
import Observation
import QuartzCore
import os.log

/// Swiping left or right on the sidebar switches profiles, with the page following the fingers (#72).
///
/// The panel hands every scroll event here first (SidebarPanel.sendEvent), before SwiftUI's vertical ScrollView
/// sees it. A gesture with phases (a trackpad's two fingers, a Magic Mouse's one) is held until its first movement
/// says which way it goes (SwipeDirectionLock): one that starts vertical is passed on as it was, held events
/// included, and never switches; one that starts horizontal moves the page and never scrolls, its momentum
/// included. A plain mouse wheel and Shift-scroll have no phases and are passed on.
///
/// Everything above the bottom bar is one page. The sidebar draws it in one of three slots (SidebarPages); while a
/// swipe goes on, the neighbouring profile's page is drawn beside it, built from the store when the swipe starts.
/// When the fingers lift past halfway or with a flick, the switch starts at once (SafariProfiles.swipe) and the
/// slots change roles: the page coming in is the sidebar's own from then on, the one going out is kept as it was,
/// scrolled where it was, until it has slid away. Nothing in the gesture's path waits on Safari, Accessibility or
/// the extension.
@Observable
final class SidebarSwipe {
    /// The three page slots: which page each holds, and where (SwipeSlots).
    private(set) var slots = SwipeSlots<TabStore.ShownContent, SwipePage>()
    /// Where the page in place is, in points to the right; its neighbours are a page's width either side.
    private(set) var offset: CGFloat = 0
    /// The page's width, from the view.
    var pageWidth: CGFloat = 260

    /// Set by the view while something that isn't a profile's page is in place (cleanup's Closed Tabs list): a
    /// horizontal swipe then does nothing.
    @ObservationIgnored var isBlocked = false

    @ObservationIgnored private let profiles: SafariProfiles
    @ObservationIgnored private let store: TabStore
    @ObservationIgnored private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "swipe")

    // The gesture under way.
    private enum Tracking {
        /// No gesture, or one that isn't the sidebar's to handle: its events pass.
        case passing
        /// Held until its first movement says which way it goes.
        case deciding(SwipeDirectionLock, held: [NSEvent])
        /// Horizontal: its events, momentum included, move the page or nothing.
        case horizontal
    }
    @ObservationIgnored private var tracking = Tracking.passing
    @ObservationIgnored private var swipe: ProfileSwipe?
    @ObservationIgnored private var settle: SwipeSettle?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastFrame: CFTimeInterval?
    @ObservationIgnored private weak var hostView: NSView?

    init(profiles: SafariProfiles, store: TabStore) {
        self.profiles = profiles
        self.store = store
    }

    /// The view whose screen paces the page's slide once the fingers lift.
    func attach(to view: NSView) {
        hostView = view
    }

    // MARK: - Scroll events

    /// Takes a scroll event before the panel's views do: the events to pass on, in order. None while a horizontal
    /// swipe has them, or while the gesture's direction isn't known yet.
    func handle(_ event: NSEvent) -> [NSEvent] {
        guard event.type == .scrollWheel else { return [event] }
        let phase = event.phase
        let momentum = event.momentumPhase
        // A plain mouse wheel, Shift-scroll: no gesture.
        guard !phase.isEmpty || !momentum.isEmpty else { return [event] }

        if !momentum.isEmpty {
            // Coasting after the fingers lifted: a horizontal swipe's is swallowed.
            if case .horizontal = tracking { return [] }
            return [event]
        }
        if phase.contains(.mayBegin) {
            // Fingers down, not moving yet: stops a list coasting, as before.
            tracking = .passing
            return [event]
        }
        if phase.contains(.began) {
            guard mayStart else {
                tracking = .passing
                return [event]
            }
            tracking = .deciding(SwipeDirectionLock(), held: [])
        }
        switch tracking {
        case .passing:
            return [event]
        case .deciding(var lock, var held):
            held.append(event)
            let ended = phase.contains(.ended) || phase.contains(.cancelled)
            switch lock.add(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY) {
            case .undecided where !ended:
                tracking = .deciding(lock, held: held)
                return []
            case .undecided, .vertical:
                tracking = .passing
                return held
            case .horizontal:
                tracking = .horizontal
                begin(at: event.timestamp, travel: lock.horizontal)
                if ended { end(at: event.timestamp, cancelled: phase.contains(.cancelled)) }
                return []
            }
        case .horizontal:
            if phase.contains(.changed) {
                move(by: event.scrollingDeltaX, at: event.timestamp)
            }
            if phase.contains(.ended) || phase.contains(.cancelled) {
                end(at: event.timestamp, cancelled: phase.contains(.cancelled))
            }
            return []
        }
    }

    /// A gesture may become a swipe: not while a tab is renamed, a mouse button is down (a drag to reorder), or
    /// something other than a profile's page is in place, or none is ("Connecting to Safari…").
    private var mayStart: Bool {
        store.renaming == nil && NSEvent.pressedMouseButtons == 0 && !isBlocked
            && (store.shownContent != nil || store.displayedContent != nil)
    }

    // MARK: - The swipe

    private func begin(at time: TimeInterval, travel: CGFloat) {
        guard let found = profiles.swipePages() else {
            // No profile is current (a private window): the page doesn't move.
            swipe = nil
            if settle != nil { finishSettling() }
            log.notice("a swipe in a window of no profile: nothing to switch to")
            return
        }
        stopSettling()
        // The sides' pages are drawn only when the page moves their way; one still sliding out that's the same
        // profile's stays, scrolled where it was, and a quick swipe back to it switches.
        slots.begin(previous: found.previous.map { .init(profileID: $0.profileID, target: $0) },
                    next: found.next.map { .init(profileID: $0.profileID, target: $0) })
        var model = ProfileSwipe(width: pageWidth, hasPrevious: found.previous != nil, hasNext: found.next != nil, offset: offset)
        model.move(by: travel, at: time)
        swipe = model
        show(model.offset)
    }

    private func move(by delta: CGFloat, at time: TimeInterval) {
        guard var model = swipe else { return }
        model.move(by: delta, at: time)
        swipe = model
        show(model.offset)
    }

    /// Puts the page at `offset`, with the neighbour it reveals drawn beside it.
    private func show(_ offset: CGFloat) {
        if let side = swipe?.incoming, slots.target(on: side) == nil {
            let store = store
            slots.reveal(side) { page in store.content(for: page.guess, profile: page.profile, profileID: page.profileID) }
        }
        if self.offset != offset {
            self.offset = offset
        }
    }

    private func end(at time: TimeInterval, cancelled: Bool) {
        guard let model = swipe else { return }
        swipe = nil
        let speed = model.speed(at: time)
        guard case .switchTo(let side) = model.end(at: time, cancelled: cancelled), let page = slots.target(on: side) else {
            settle(from: offset, speed: speed)
            return
        }
        // What's on screen now goes out as it is; then the switch starts, and the page coming in is the sidebar's own.
        let outgoing = store.displayedContent
        let outgoingProfile = profiles.highlightedID
        guard profiles.swipe(to: page) else {
            log.notice("a swipe's switch didn't start: the page springs back")
            settle(from: offset, speed: speed)
            return
        }
        slots.switched(to: side, outgoing: outgoing, outgoingProfile: outgoingProfile)
        let moved = offset + CGFloat(side.rawValue) * pageWidth
        offset = moved
        settle(from: moved, speed: speed)
    }

    // MARK: - Sliding the rest of the way

    private func settle(from offset: CGFloat, speed: CGFloat) {
        settle = SwipeSettle(offset: offset, velocity: speed)
        lastFrame = nil
        guard settle?.isDone == false else {
            finishSettling()
            return
        }
        if displayLink == nil, let view = hostView {
            let link = view.displayLink(target: DisplayLinkTarget { [weak self] link in self?.frame(link) },
                                        selector: #selector(DisplayLinkTarget.fire(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        if displayLink == nil {
            finishSettling()
        }
    }

    private func frame(_ link: CADisplayLink) {
        guard var current = settle else {
            stopSettling()
            return
        }
        let now = link.targetTimestamp
        let dt = lastFrame.map { now - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastFrame = now
        current.step(min(max(dt, 0), 0.05))
        settle = current
        if current.isDone {
            finishSettling()
        } else {
            show(current.offset)
        }
    }

    /// Stops the slide where it is: a new swipe carries on from there.
    private func stopSettling() {
        settle = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    private func finishSettling() {
        stopSettling()
        offset = 0
        slots.settled()
    }
}

/// The display link's target: it holds its target strongly, so this calls back without keeping SidebarSwipe alive.
private final class DisplayLinkTarget: NSObject {
    private let action: (CADisplayLink) -> Void

    init(_ action: @escaping (CADisplayLink) -> Void) {
        self.action = action
    }

    @objc func fire(_ link: CADisplayLink) {
        action(link)
    }
}
