import AppKit
import Observation
import os.log

/// Keeps the sidebar panel attached to the left edge of Safari's front window, makes
/// room for it by narrowing Safari when needed, and switches to a hover-to-reveal
/// overlay while Safari is full screen, or in any window when the sidebar hides automatically.
final class DockController {
    private enum Mode: Equatable {
        case hidden
        case docked
        case overlay(OverlayPlace)
    }

    let panel: SidebarPanel
    private let tracker: SafariTracker
    private let settings: AppSettings
    private let store: TabStore

    private var mode: Mode = .hidden
    private var settleWork: DispatchWorkItem?
    private var healthTimer: Timer?
    private var isEditing = false

    private var overlayTimer: Timer?
    /// Where the overlay's panel goes and the strip that brings it out, for the current window.
    private var overlayLayout: OverlayLayout?
    /// Whether the overlay is out, and why (SidebarOverlay.swift).
    private var overlayReveal = OverlayReveal()

    /// Width + gap the last layout used, to keep Safari flush when the width changes.
    private var appliedInset: Double?

    /// Below this, narrowing Safari to fit the sidebar would make it unusable.
    private let minimumSafariWidth: CGFloat = 480

    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "dock")
    private var lastNote = ""

    /// Logs state changes (not every update) so `log stream` shows what the dock is doing.
    private func note(_ state: String) {
        guard state != lastNote else { return }
        lastNote = state
        log.notice("\(state, privacy: .public)")
    }

    init(panel: SidebarPanel, tracker: SafariTracker, settings: AppSettings, store: TabStore) {
        self.panel = panel
        self.tracker = tracker
        self.settings = settings
        self.store = store
    }

    func start() {
        tracker.onEvent = { [weak self] event in self?.handle(event) }
        // Any click on the sidebar means "take me to Safari".
        panel.onMouseDown = { [weak self] in self?.bringSafariForward() }
        tracker.readsToolbarInWindows = settings.hidesAutomatically
        tracker.start()
        observeSettings()
        update(makeRoom: true)

        // Picks up Accessibility access being granted, Safari windows appearing, etc., and
        // puts the sidebar right after changes macOS didn't announce, including a switch to
        // another Safari window that the window notifications missed.
        // The reads of Safari's windows happen off the main thread; this runs when they're in. If
        // Safari is slow to answer, that is later, and the sidebar stays as it was meanwhile.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasAttached = self.tracker.isAttached
                self.tracker.attachIfNeeded()
                self.tracker.refreshWindow { [weak self] windowChanged in
                    guard let self else { return }
                    if !wasAttached && self.tracker.isAttached || self.mode == .hidden || windowChanged {
                        self.update(makeRoom: true)
                    } else if let problem = self.placementProblem() {
                        self.log.notice("fixing: \(problem, privacy: .public)")
                        self.update(makeRoom: NSEvent.pressedMouseButtons == 0)
                    }
                }
            }
        }
    }

    private func handle(_ event: SafariTracker.Event) {
        switch event {
        case .moved, .resized:
            update(makeRoom: false)
            scheduleMakeRoom()
        case .launched:
            store.safariDidLaunch()
            update(makeRoom: true)
            store.requestSnapshot()
        case .focusChanged, .visibilityChanged, .windowChanged:
            update(makeRoom: true)
        case .titleChanged:
            // Only the store's copy of the title, which picks the window to list. Nothing about where
            // the window is has changed, so the layout isn't done again.
            if let window = tracker.window {
                store.dockedWindowTitle = tracker.title(of: window)
            }
        case .terminated:
            store.safariDidTerminate()
            hide()
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.sidebarVisible
            _ = settings.hidesAutomatically
            _ = settings.width
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    private func settingsChanged() {
        if tracker.readsToolbarInWindows != settings.hidesAutomatically {
            tracker.readsToolbarInWindows = settings.hidesAutomatically
            // The overlay starts below the toolbar, which a normal window's last read didn't include.
            tracker.refreshWindow(full: false) { [weak self] _ in self?.update(makeRoom: false) }
        }
        guard settings.sidebarVisible else {
            restoreSafariFrame()
            hide()
            return
        }
        keepSafariFlush()
        update(makeRoom: true)
    }

    // MARK: - Layout

    func update(makeRoom: Bool) {
        store.safariIsFrontmost = tracker.isSafariFrontmost

        let hideReason: String?
        if !settings.sidebarVisible {
            hideReason = "sidebar turned off"
        } else if !tracker.isTrusted {
            hideReason = "no Accessibility access"
        } else if tracker.app == nil || tracker.app?.isTerminated == true {
            hideReason = "Safari not running"
        } else if tracker.app?.isHidden == true {
            hideReason = "Safari hidden"
        } else if tracker.window == nil {
            hideReason = "no Safari browser window found (attached: \(tracker.isAttached))"
        } else {
            hideReason = nil
        }
        guard hideReason == nil, let window = tracker.window, let axFrame = tracker.frame(of: window) else {
            note("hidden: \(hideReason ?? "window has no frame")")
            hide()
            return
        }

        let title = tracker.title(of: window)
        if store.dockedWindowTitle != title {
            store.dockedWindowTitle = title
        }

        // The sidebar follows Safari between Spaces (`moveToActiveSpace`), so only show it on
        // the Space where its window is. Otherwise it would cover other apps' Spaces, and
        // full-screen videos, which Safari shows in their own window and Space.
        if !tracker.isOnActiveSpace(window) {
            note("hidden: Safari window is on another Space")
            hide()
            return
        }

        switch SidebarPlacement.choose(fullScreen: tracker.isFullScreen(window), hidesAutomatically: settings.hidesAutomatically) {
        case .overlay(.fullScreen):
            let layout = fullScreenLayout(on: screen(containing: axFrame), window: window)
            showOverlay(.fullScreen, layout: layout)
            note("full screen overlay: panel at \(layout.panel)")
            return
        case .overlay(.window):
            // Safari keeps its whole window. If the sidebar had made room beside it, give it back.
            if appliedInset != nil {
                restoreSafariFrame { [weak self] in self?.update(makeRoom: false) }
                appliedInset = nil
            }
            let layout = windowLayout(for: axFrame, window: window)
            showOverlay(.window, layout: layout)
            note("hidden until pointed at: Safari at \(axFrame.integral), panel at \(layout.panel)")
            return
        case .docked:
            break
        }
        stopOverlay()

        let target = dockedFrame(beside: axFrame)
        panel.style.attached = true
        if panel.frame != target {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        }
        panel.level = .normal
        orderPanel(below: window)
        mode = .docked
        appliedInset = settings.width
        note("docked: Safari at \(axFrame.integral), panel at \(panel.frame), on screen: \(panel.isVisible && panel.isOnActiveSpace)")

        if makeRoom {
            self.makeRoom(for: window)
        }
    }

    /// The panel's frame beside a Safari window at `axFrame`. It reaches under Safari's
    /// window by `cornerFill` to fill its corner notches.
    private func dockedFrame(beside axFrame: CGRect) -> NSRect {
        let frame = axFrame.flippedScreenCoordinates
        return NSRect(
            x: frame.minX - settings.width,
            y: frame.minY,
            width: settings.width + SidebarPanel.cornerFill,
            height: frame.height
        ).integral
    }

    /// Why the sidebar isn't where `update` would put it, if it isn't. macOS doesn't announce
    /// every change: a swipe toward another Space that's taken back never changes Spaces, and
    /// leaving full screen can finish after the last event about it.
    private func placementProblem() -> String? {
        guard mode != .hidden else { return nil }
        guard settings.sidebarVisible, tracker.app?.isHidden == false,
              let window = tracker.window, let frame = tracker.frame(of: window) else {
            return "Safari or its window is gone or hidden"
        }
        if !tracker.isOnActiveSpace(window) {
            return "Safari's window is on another Space"
        }
        let wanted = SidebarPlacement.choose(fullScreen: tracker.isFullScreen(window), hidesAutomatically: settings.hidesAutomatically)
        switch (mode, wanted) {
        case (.hidden, _):
            return nil
        // Safari's bars come and go without the window moving or changing size (the Favourites bar,
        // the find bar, the tab layout, the full-screen toolbar sliding down), so nothing announces
        // them: the last read may only now include them (#35). Compared with the layout last applied,
        // not the panel's frame, so a frame AppKit adjusts can't make this fix it every second.
        case (.overlay(.fullScreen), .overlay(.fullScreen)):
            return overlayLayout != fullScreenLayout(on: screen(containing: frame), window: window) ? "sidebar isn't below Safari's bars in full screen" : nil
        case (.overlay(.fullScreen), _):
            return "Safari left full screen"
        case (_, .overlay(.fullScreen)):
            return "Safari is full screen"
        case (.overlay(.window), .overlay(.window)):
            return overlayLayout != windowLayout(for: frame, window: window) ? "sidebar isn't where it comes out over Safari's window" : nil
        case (.overlay(.window), .docked):
            return "the sidebar no longer hides automatically"
        case (.docked, .overlay(.window)):
            return "the sidebar hides automatically now"
        case (.docked, .docked):
            break
        }
        if !panel.isVisible || panel.alphaValue < 1 || !tracker.isOnActiveSpace(windowNumber: panel.windowNumber) {
            return "sidebar isn't showing"
        }
        if panel.frame != dockedFrame(beside: frame) {
            return "sidebar isn't beside Safari"
        }
        if let number = tracker.windowNumber(of: window) {
            let behind = normalWindows(.optionOnScreenBelowWindow, relativeTo: number).first
            if let behind, behind[kCGWindowNumber as String] as? Int != panel.windowNumber {
                let inFront = normalWindows(.optionOnScreenAboveWindow, relativeTo: number)
                    .contains { $0[kCGWindowNumber as String] as? Int == panel.windowNumber }
                let owner = behind[kCGWindowOwnerName as String] as? String ?? "another window"
                return inFront ? "sidebar is in front of Safari's window" : "\(owner) is between Safari's window and the sidebar"
            }
        }
        return nil
    }

    /// On-screen windows at the normal level above or below the given one, front to back.
    private func normalWindows(_ option: CGWindowListOption, relativeTo number: Int) -> [[String: Any]] {
        let windows = CGWindowListCopyWindowInfo([option], CGWindowID(number)) as? [[String: Any]] ?? []
        return windows.filter { $0[kCGWindowLayer as String] as? Int == 0 }
    }

    /// Keeps the panel directly behind Safari's window: in front of everything Safari is in
    /// front of, and with its corner fill hidden under Safari.
    private func orderPanel(below window: AXUIElement) {
        // Left on another Space (such as the one Safari just left full screen from), the panel
        // has to be ordered out and back in to move to the Space being shown.
        if panel.isVisible && !tracker.isOnActiveSpace(windowNumber: panel.windowNumber) {
            panel.orderOut(nil)
        }
        if let number = tracker.windowNumber(of: window) {
            panel.order(.below, relativeTo: number)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func hide() {
        stopOverlay()
        if panel.isVisible {
            panel.orderOut(nil)
        }
        mode = .hidden
    }

    /// While the user drags or resizes Safari, wait until they stop before pushing the
    /// window out from under the sidebar.
    private func scheduleMakeRoom() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, NSEvent.pressedMouseButtons & 1 == 0 else {
                self?.scheduleMakeRoom()
                return
            }
            if let window = self.tracker.window {
                self.makeRoom(for: window)
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Only while the sidebar is docked: when it's hidden or turned off, Safari can use the
    /// whole screen, and pushing it would undo the user's resizing.
    ///
    /// Moves the window rather than narrowing it, if the screen has room. Safari can open a
    /// new window at the left edge with the size of an earlier one, so narrowing it would make
    /// each new window narrower than the one before.
    private func makeRoom(for window: AXUIElement) {
        guard mode == .docked, let frame = tracker.frame(of: window), !tracker.isFullScreen(window) else { return }
        let visible = screen(containing: frame).visibleFrame.flippedScreenCoordinates
        let left = visible.minX + settings.width
        guard frame.minX < left - 0.5 else { return }

        let width = max(min(frame.width, visible.maxX - left), minimumSafariWidth)
        let target = CGRect(x: left, y: frame.minY, width: width, height: frame.height)
        // The write waits on Safari, so it's made off the main thread; the sidebar follows once
        // the window reports where it ended up.
        tracker.setFrame(target, of: window) { [weak self] result in
            guard let self else { return }
            self.log.notice("made room: Safari \(String(describing: frame), privacy: .public) → \(String(describing: result), privacy: .public)")
            self.update(makeRoom: false)
        }
    }

    /// When the sidebar width changes and Safari was sitting right against it, move
    /// Safari's left edge along with it.
    private func keepSafariFlush() {
        guard let previous = appliedInset, !settings.hidesAutomatically,
              let window = tracker.window,
              let frame = tracker.frame(of: window),
              !tracker.isFullScreen(window) else { return }
        let visible = screen(containing: frame).visibleFrame.flippedScreenCoordinates
        guard abs(frame.minX - (visible.minX + previous)) < 2 else { return }
        let left = visible.minX + settings.width
        let width = max(frame.maxX - left, minimumSafariWidth)
        tracker.setFrame(CGRect(x: left, y: frame.minY, width: width, height: frame.height), of: window) { [weak self] _ in
            self?.update(makeRoom: false)
        }
        appliedInset = settings.width
    }

    /// Gives Safari its space back when the sidebar is hidden, starts hiding automatically, or the
    /// app quits. When quitting, `waiting` holds the app until Safari has been moved, since nothing
    /// runs afterwards. Otherwise `completion` runs once Safari has been moved.
    func restoreSafariFrame(waiting: Bool = false, then completion: (() -> Void)? = nil) {
        guard let inset = appliedInset,
              let window = tracker.window,
              let frame = tracker.frame(of: window),
              !tracker.isFullScreen(window) else { return }
        let visible = screen(containing: frame).visibleFrame.flippedScreenCoordinates
        guard abs(frame.minX - (visible.minX + inset)) < 2 else { return }
        let target = CGRect(x: visible.minX, y: frame.minY, width: frame.maxX - visible.minX, height: frame.height)
        if waiting {
            tracker.setFrameAndWait(target, of: window)
        } else {
            tracker.setFrame(target, of: window) { _ in completion?() }
        }
    }

    private func screen(containing axFrame: CGRect) -> NSScreen {
        let frame = axFrame.flippedScreenCoordinates
        let best = NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
        return best ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Overlay

    /// A full-screen window can't be resized, so the sidebar stays hidden and slides out
    /// over the page when the pointer reaches the left edge of the screen (or the Side Tabs
    /// toolbar button / shortcut is used). When the sidebar hides automatically, a normal window
    /// gets the same, from the window's left edge.
    private func showOverlay(_ place: OverlayPlace, layout: OverlayLayout) {
        if case .overlay(let previous) = mode, previous != place {
            // Safari went into or out of full screen with the setting on: what was out belonged to
            // the other place.
            stopOverlay()
        }
        mode = .overlay(place)
        overlayLayout = layout
        // Out of sight before it changes shape and level, so a sidebar docked a moment ago never
        // shows over Safari on its way out.
        if !overlayReveal.isRevealed && panel.isVisible {
            panel.orderOut(nil)
        }
        panel.style.attached = false
        // Sized as soon as the place is known, so revealing it later is instant.
        if panel.frame != layout.panel {
            panel.setFrame(layout.panel, display: true)
            panel.invalidateShadow()
        }
        panel.level = .floating
        if overlayReveal.isRevealed && !panel.isVisible {
            panel.orderFrontRegardless()
        }
        if overlayTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollOverlay() }
            }
            RunLoop.main.add(timer, forMode: .common)
            overlayTimer = timer
        }
    }

    /// Starts below Safari's toolbar and the bars under it, so the sidebar never covers them.
    private func fullScreenLayout(on screen: NSScreen, window: AXUIElement) -> OverlayLayout {
        OverlayLayout.fullScreen(
            screen: screen.frame,
            toolbarBottom: tracker.toolbarBottom(of: window),
            mainHeight: NSScreen.screens.first?.frame.height ?? screen.frame.maxY,
            width: settings.width
        )
    }

    /// Over the page of a normal window at `axFrame`, below its toolbar and the bars under it, with
    /// the strip along its left edge.
    private func windowLayout(for axFrame: CGRect, window: AXUIElement) -> OverlayLayout {
        let screen = screen(containing: axFrame)
        return OverlayLayout.window(
            frame: axFrame.flippedScreenCoordinates,
            visible: screen.visibleFrame,
            toolbarBottom: tracker.toolbarBottom(of: window),
            mainHeight: NSScreen.screens.first?.frame.height ?? screen.frame.maxY,
            width: settings.width
        )
    }

    private func stopOverlay() {
        overlayTimer?.invalidate()
        overlayTimer = nil
        overlayLayout = nil
        overlayReveal = OverlayReveal()
        panel.alphaValue = 1
    }

    /// Whether the toolbar button, its shortcut and the menu bar item slide the sidebar out or
    /// away rather than turning it off. In a normal window another app can be in front, as when the
    /// menu bar item is used from it; the sidebar can't come out over Safari then, so the item turns
    /// it off as its name says.
    var togglesOverlay: Bool {
        switch mode {
        case .overlay(.fullScreen): true
        case .overlay(.window): tracker.isSafariFrontmost
        case .hidden, .docked: false
        }
    }

    /// The toolbar button / shortcut while there's an overlay: slide the sidebar out or put it away.
    func toggleOverlay() {
        guard case .overlay = mode else { return }
        perform(overlayReveal.toggle(), because: "toolbar button or shortcut")
    }

    private func pollOverlay() {
        guard let layout = overlayLayout else { return }
        // Keep it out while a context menu or drag is in progress, or while renaming.
        let holding = isEditing || RunLoop.current.currentMode == .eventTracking || NSEvent.pressedMouseButtons != 0
        let safariInFront = tracker.isSafariFrontmost
        let action = overlayReveal.poll(
            pointer: NSEvent.mouseLocation,
            strip: layout.strip,
            panel: panel.frame,
            safariInFront: safariInFront,
            holding: holding,
            // Never over another Space or a full-screen video, even in the moment before the
            // dock hears about the switch.
            mayReveal: { tracker.window.map { tracker.isOnActiveSpace($0) } ?? false }
        )
        perform(action, because: action == .reveal ? "pointer at the edge" : safariInFront ? "pointer left" : "Safari isn't in front")
    }

    private func perform(_ action: OverlayReveal.Action, because reason: String) {
        switch action {
        case .none:
            return
        case .reveal:
            revealOverlay()
        case .conceal:
            concealOverlay()
        }
        log.notice("overlay \(action == .reveal ? "out" : "away", privacy: .public): \(reason, privacy: .public)")
    }

    private func revealOverlay() {
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func concealOverlay() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.overlayReveal.isRevealed else { return }
                // Safari may have left full screen while the sidebar faded out. If the
                // sidebar is docked beside it now, leave it showing.
                if case .overlay = self.mode {
                    self.panel.orderOut(nil)
                }
                self.panel.alphaValue = 1
            }
        })
    }

    // MARK: - Focus

    /// Renaming needs keyboard input in the panel; afterwards hand focus back to Safari.
    func setEditing(_ editing: Bool) {
        isEditing = editing
        if editing {
            panel.makeKey()
        } else {
            tracker.focusSafari()
        }
    }

    func openSafariAddressBar() {
        tracker.openLocation()
    }

    /// Clicking the sidebar while another app is in front should bring Safari forward.
    func bringSafariForward() {
        if tracker.isSafariFrontmost {
            tracker.raiseDockedWindowIfNeeded()
        } else {
            tracker.focusSafari()
        }
        // The click itself brings the sidebar in front of Safari; once it's handled, put the
        // sidebar back behind.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mode == .docked, let window = self.tracker.window else { return }
            self.orderPanel(below: window)
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
