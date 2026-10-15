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
    private var hover = SidebarAutoHide()
    private var overlayLayout: SidebarOverlayLayout?
    private var overlayFullScreen = false
    private var overlayWindowNumber: Int?

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

        // Picks up Accessibility access being granted, Safari windows appearing, etc., and
        // puts the sidebar right after changes macOS didn't announce.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasAttached = self.tracker.isAttached
                self.tracker.attachIfNeeded()
                if !wasAttached && self.tracker.isAttached || self.mode == .hidden {
                    self.update(makeRoom: true)
                } else if let problem = self.placementProblem() {
                    self.log.notice("fixing: \(problem, privacy: .public)")
                    self.update(makeRoom: NSEvent.pressedMouseButtons == 0)
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
            _ = settings.autoHideSidebar
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
        if settings.autoHideSidebar {
            restoreSafariFrame()
        } else { keepSafariFlush() }
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
            showOverlay(on: screen(containing: axFrame), window: window, fullScreen: true)
            return
        }
        if settings.autoHideSidebar {
            restoreSafariFrame()
            let restoredFrame = tracker.frame(of: window) ?? axFrame
            note("auto-hide overlay for ‘\(title ?? "untitled")’")
            showOverlay(on: screen(containing: restoredFrame), window: window, fullScreen: false)
            return
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
        note("docked to “\(title ?? "untitled")”: Safari at \(axFrame.integral), panel at \(panel.frame), on screen: \(panel.isVisible && panel.isOnActiveSpace)")

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
        let fullScreen = tracker.isFullScreen(window)
        if mode == .overlay {
            guard fullScreen || settings.autoHideSidebar else { return "hover mode disabled" }
            guard overlayFullScreen == fullScreen else { return "Safari changed fullscreen mode" }
            guard overlayWindowNumber == tracker.windowNumber(of: window) else { return "Safari changed windows" }
            let expected = layoutForOverlay(on: screen(containing: frame), window: window, fullScreen: fullScreen)
            guard expected == overlayLayout, expected.map({ $0.frame == panel.frame }) ?? true else { return "overlay bounds changed" }
            return nil
        }
        if fullScreen || settings.autoHideSidebar {
            return "Safari needs a hover overlay"
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
        guard !settings.autoHideSidebar else { return }
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
        guard !settings.autoHideSidebar, let frame = tracker.frame(of: window), !tracker.isFullScreen(window) else { return }
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
        guard !settings.autoHideSidebar, let previous = appliedInset,
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
        appliedInset = nil
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

    // MARK: - Hover overlays

    private var overlayCanStayForeground: Bool {
        tracker.isSafariFrontmost || (isEditing && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == SideTabsBridge.appBundleIdentifier)
    }

    private func showOverlay(on screen: NSScreen, window: AXUIElement, fullScreen: Bool) {
        let number = tracker.windowNumber(of: window)
        if mode != .overlay || overlayFullScreen != fullScreen || overlayWindowNumber != number {
            stopOverlay()
        }
        mode = .overlay
        overlayFullScreen = fullScreen
        overlayWindowNumber = number
        overlayScreen = screen
        panel.style.attached = false
        layOutOverlay(on: screen, window: window)
        panel.level = .floating
        if hover.revealed && overlayCanStayForeground && overlayLayout != nil {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else if panel.isVisible { panel.orderOut(nil) }
        if overlayTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollOverlay() }
            }
            RunLoop.main.add(timer, forMode: .common)
            overlayTimer = timer
        }
    }

    private func layoutForOverlay(on screen: NSScreen, window: AXUIElement, fullScreen: Bool) -> SidebarOverlayLayout? {
        guard let axFrame = tracker.frame(of: window) else { return nil }
        let bounds = fullScreen ? screen.frame : axFrame.flippedScreenCoordinates
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        let toolbarBottom = tracker.toolbarBottom(of: window).map { mainHeight - $0 }
        return SidebarOverlayLayout.make(window: bounds,
            screen: fullScreen ? screen.frame : screen.visibleFrame,
            toolbarBottom: toolbarBottom, width: settings.width, fullScreen: fullScreen)
    }

    private func layOutOverlay(on screen: NSScreen, window: AXUIElement) {
        overlayLayout = layoutForOverlay(on: screen, window: window, fullScreen: overlayFullScreen)
        if let target = overlayLayout?.frame, panel.frame != target {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        }
    }

    private func stopOverlay() {
        overlayTimer?.invalidate(); overlayTimer = nil
        overlayScreen = nil; overlayLayout = nil; overlayWindowNumber = nil
        hover.reset()
        panel.alphaValue = 1
    }

    var isUsingHoverOverlay: Bool { mode == .overlay }

    func toggleOverlay() {
        // Re-enabling a disabled sidebar can precede the settings observer's update.
        if mode != .overlay { update(makeRoom: false) }
        guard mode == .overlay, overlayLayout != nil else { return }
        applyHoverAction(hover.toggle())
    }

    private func pollOverlay() {
        guard overlayScreen != nil, let window = tracker.window,
              settings.sidebarVisible, tracker.isTrusted, tracker.app?.isHidden == false,
              tracker.isOnActiveSpace(window), overlayWindowNumber == tracker.windowNumber(of: window),
              tracker.isFullScreen(window) == overlayFullScreen,
              overlayFullScreen || settings.autoHideSidebar else {
            hover.reset()
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        let foreground = overlayCanStayForeground
        guard foreground, let layout = overlayLayout else {
            hover.reset()
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        let mouse = NSEvent.mouseLocation
        let tracking = RunLoop.current.currentMode == .eventTracking || NSEvent.pressedMouseButtons != 0
        let action = hover.update(now: ProcessInfo.processInfo.systemUptime,
            atEdge: layout.trigger.contains(mouse), inside: panel.frame.insetBy(dx: -12, dy: -12).contains(mouse),
            foreground: foreground, editing: isEditing, tracking: tracking)
        applyHoverAction(action)
    }

    private func applyHoverAction(_ action: SidebarAutoHide.Action) {
        switch action {
        case .none: break
        case .reveal:
            log.info("hover overlay revealed; full screen: \(self.overlayFullScreen)")
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        case .conceal:
            log.info("hover overlay concealed; full screen: \(self.overlayFullScreen)")
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.hover.revealed else { return }
                    if self.mode == .overlay { self.panel.orderOut(nil) }
                    self.panel.alphaValue = 1
                }
            })
        }
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
        // A space editor or inline rename needs to keep keyboard focus in Side Tabs.
        guard !isEditing else { return }
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
