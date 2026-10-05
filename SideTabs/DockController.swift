import AppKit
import Observation
import os.log

/// Keeps the sidebar panel attached to the left edge of Safari's front window, makes
/// room for it by narrowing Safari when needed, and switches to a hover-to-reveal
/// overlay while Safari is full screen.
final class DockController {
    private enum Mode {
        case hidden
        case docked
        case overlay
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
    private var overlayScreen: NSScreen?
    private var overlayRevealed = false
    /// Revealed with the shortcut rather than by hovering.
    private var overlayPinned = false
    private var mouseEnteredOverlay = false

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
        tracker.start()
        observeSettings()
        update(makeRoom: true)

        // Picks up Accessibility access being granted, Safari windows appearing, etc.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasAttached = self.tracker.isAttached
                self.tracker.attachIfNeeded()
                if !wasAttached && self.tracker.isAttached || self.mode == .hidden {
                    self.update(makeRoom: true)
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
            update(makeRoom: true)
            store.requestSnapshot()
        case .focusChanged, .visibilityChanged:
            update(makeRoom: true)
        case .terminated:
            store.safariDidTerminate()
            hide()
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.sidebarVisible
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

        if tracker.isFullScreen(window) {
            note("full screen overlay for “\(title ?? "untitled")”")
            showOverlay(on: screen(containing: axFrame), window: window)
            return
        }
        stopOverlay()

        // The panel reaches under Safari's window by `cornerFill` to fill its corner notches.
        let frame = axFrame.flippedScreenCoordinates
        let target = NSRect(
            x: frame.minX - settings.width,
            y: frame.minY,
            width: settings.width + SidebarPanel.cornerFill,
            height: frame.height
        ).integral
        panel.style.attached = true
        if panel.frame != target {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        }
        panel.level = .normal
        orderPanel(below: window)
        mode = .docked
        appliedInset = settings.width
        note("docked to “\(title ?? "untitled")”: Safari at \(axFrame.integral), panel at \(panel.frame), on screen: \(panel.isVisible && panel.isOnActiveSpace)")

        if makeRoom {
            self.makeRoom(for: window)
        }
    }

    /// Keeps the panel directly behind Safari's window: in front of everything Safari is in
    /// front of, and with its corner fill hidden under Safari.
    private func orderPanel(below window: AXUIElement) {
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

    private func makeRoom(for window: AXUIElement) {
        guard let frame = tracker.frame(of: window), !tracker.isFullScreen(window) else { return }
        let visible = screen(containing: frame).visibleFrame.flippedScreenCoordinates
        let left = visible.minX + settings.width
        guard frame.minX < left - 0.5 else { return }

        let right = min(frame.maxX, visible.maxX)
        let width = max(right - left, minimumSafariWidth)
        let target = CGRect(x: left, y: frame.minY, width: width, height: frame.height)
        tracker.setFrame(target, of: window)
        let result = String(describing: tracker.frame(of: window))
        log.notice("made room: Safari \(String(describing: frame), privacy: .public) → \(result, privacy: .public)")
    }

    /// When the sidebar width changes and Safari was sitting right against it, move
    /// Safari's left edge along with it.
    private func keepSafariFlush() {
        guard let previous = appliedInset,
              let window = tracker.window,
              let frame = tracker.frame(of: window),
              !tracker.isFullScreen(window) else { return }
        let visible = screen(containing: frame).visibleFrame.flippedScreenCoordinates
        guard abs(frame.minX - (visible.minX + previous)) < 2 else { return }
        let left = visible.minX + settings.width
        let width = max(frame.maxX - left, minimumSafariWidth)
        tracker.setFrame(CGRect(x: left, y: frame.minY, width: width, height: frame.height), of: window)
        appliedInset = settings.width
    }

    /// Gives Safari its space back when the sidebar is hidden or the app quits.
    func restoreSafariFrame() {
        guard let inset = appliedInset,
              let window = tracker.window,
              let frame = tracker.frame(of: window),
              !tracker.isFullScreen(window) else { return }
        let visible = screen(containing: frame).visibleFrame.flippedScreenCoordinates
        guard abs(frame.minX - (visible.minX + inset)) < 2 else { return }
        tracker.setFrame(CGRect(x: visible.minX, y: frame.minY, width: frame.maxX - visible.minX, height: frame.height), of: window)
    }

    private func screen(containing axFrame: CGRect) -> NSScreen {
        let frame = axFrame.flippedScreenCoordinates
        let best = NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
        return best ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Full screen

    /// A full-screen window can't be resized, so the sidebar stays hidden and slides out
    /// over the page when the pointer reaches the left edge of the screen (or the Side Tabs
    /// toolbar button / shortcut is used).
    private func showOverlay(on screen: NSScreen, window: AXUIElement) {
        mode = .overlay
        overlayScreen = screen
        panel.style.attached = false
        layOutOverlay(on: screen, window: window)
        panel.level = .floating
        if overlayRevealed {
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
        if overlayTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollOverlay() }
            }
            RunLoop.main.add(timer, forMode: .common)
            overlayTimer = timer
        }
    }

    /// Starts below Safari's toolbar and tab bar so the sidebar never covers them. Sized
    /// when full screen is detected, so revealing it later is instant.
    private func layOutOverlay(on screen: NSScreen, window: AXUIElement) {
        let inset: CGFloat = 8
        // Safari's full-screen toolbar is about 52 pt tall; never start above that.
        let minimumToolbar: CGFloat = 60
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        let screenTop = mainHeight - screen.frame.maxY
        let toolbarBottom = max(tracker.toolbarBottom(of: window) ?? 0, screenTop + minimumToolbar)
        let top = mainHeight - toolbarBottom - inset
        let bottom = screen.frame.minY + inset
        let target = NSRect(
            x: screen.frame.minX + inset,
            y: bottom,
            width: settings.width,
            height: max(top - bottom, 200)
        ).integral
        if panel.frame != target {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        }
    }

    private func stopOverlay() {
        overlayTimer?.invalidate()
        overlayTimer = nil
        overlayScreen = nil
        overlayRevealed = false
        overlayPinned = false
        mouseEnteredOverlay = false
        panel.alphaValue = 1
    }

    var isShowingFullScreenOverlay: Bool { mode == .overlay }

    /// The toolbar button / shortcut in full screen: slide the sidebar out or put it away.
    func toggleOverlay() {
        guard mode == .overlay else { return }
        if overlayRevealed {
            concealOverlay()
        } else {
            overlayPinned = true
            revealOverlay()
        }
    }

    private func pollOverlay() {
        guard let screen = overlayScreen, tracker.isSafariFrontmost else {
            if overlayRevealed {
                concealOverlay()
            }
            return
        }
        let mouse = NSEvent.mouseLocation
        let edge = screen.frame
        if !overlayRevealed {
            let atLeftEdge = mouse.x <= edge.minX + 2 && mouse.y >= edge.minY && mouse.y <= edge.maxY
            if atLeftEdge {
                revealOverlay()
            }
            return
        }

        let inside = panel.frame.insetBy(dx: -24, dy: -24).contains(mouse)
        if inside {
            mouseEnteredOverlay = true
        }
        // Opened with the shortcut: stay until the pointer has visited the sidebar and left.
        if overlayPinned && !mouseEnteredOverlay {
            return
        }
        // Keep it open while a context menu or drag is in progress, or while renaming.
        let tracking = RunLoop.current.currentMode == .eventTracking || NSEvent.pressedMouseButtons != 0
        if !isEditing && !tracking && !inside {
            concealOverlay()
        }
    }

    private func revealOverlay() {
        overlayRevealed = true
        mouseEnteredOverlay = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func concealOverlay() {
        overlayRevealed = false
        overlayPinned = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.overlayRevealed else { return }
                self.panel.orderOut(nil)
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
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
