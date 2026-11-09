import AppKit
import os.log

/// "Minimize other profiles' windows" (#42), on the main thread: which profile is current, when the other
/// profiles' windows are minimized and the current one's come back, the Dock icon rule, and the saved
/// list. Owned by SafariProfiles, which tells it about the docked window and runs the switches.
///
/// The rules are MinimizeRules'; the Accessibility work is WindowMinimizer's, on ProfileReader's queue,
/// one window at a time. Nothing here waits for Safari.
///
/// - **The current profile** is the profile of the last browser window in front whose profile is known.
///   A private window, or one whose profile can't be told, doesn't change it, and neither does a window on
///   a desktop that isn't shown (Safari's next window after a close can be one): `dockedProfileID` is nil
///   for those, so the two are kept apart.
/// - **A sweep** follows every change of the current profile: the other profiles' windows are minimized
///   and the new one's come back. Also when the setting is turned on, when Side Tabs starts with Safari
///   running, once Safari has started, and when another profile's window opens behind the front one.
///   A button switch sweeps itself once its window is main (ProfileSwitcher); while it's in progress,
///   changes don't sweep, and when it's done, whatever is current is swept for if it wasn't.
final class MinimizeOtherProfiles {
    private unowned let host: SafariProfiles
    private let settings: AppSettings
    private let tracker: SafariTracker
    private let reader: ProfileReader
    private let minimizer: WindowMinimizer
    private let fileURL: URL
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "profiles")

    private var isOn: Bool { settings.minimizesOtherProfiles }

    /// The profile of the last browser window in front whose profile is known.
    private(set) var currentProfileID: UUID?

    /// The window last reported in front, so a repeated report of it isn't a change.
    private struct Front: Equatable {
        let number: Int?
        let profile: UUID?
    }
    private var lastFront: Front?

    /// The profile the last sweep was asked for.
    private var sweptFor: UUID?
    /// A sweep that couldn't run when it was wanted (during a switch, while Safari starts, before the current
    /// profile is known, while Safari isn't running), and why.
    private var deferred: (reason: MinimizeReason, left: UUID?)?

    /// A switch in progress. Until it's done, changes of the front window don't sweep: it does.
    private struct SwitchInFlight {
        let token: Int
        let profile: UUID
        let left: UUID?
        let reason: MinimizeReason
        /// For the Dock icon: the window macOS brought out, whose change is applied if the switch fails.
        let broughtOut: Front?
    }
    private var switchInFlight: SwitchInFlight?
    private var switchToken = 0

    // Safari starting.
    /// Safari launched while Side Tabs was running: no sweep until it stops opening windows and the front
    /// window's profile is known, so a window about to come to the front isn't minimized.
    private var safariStarting = false
    private var lastWindowCreatedAt = Date.distantPast
    private var startCheck: DispatchWorkItem?
    /// No new window for this long: Safari has stopped opening windows.
    static let startQuiet: TimeInterval = 1
    /// Side Tabs starting this soon after Safari launched counts as Safari starting.
    static let safariJustLaunched: TimeInterval = 10

    // The list, as WindowMinimizer last reported it, and saving it.
    private var list = MinimizedList()
    private var saveWork: DispatchWorkItem?

    // The Dock icon (DockIconRule).
    /// Watches for a click on Safari's Dock icon. Nil until wired.
    var dockIconWatcher: (any SafariDockIconWatching)? {
        didSet {
            oldValue?.disarm()
            oldValue?.onClick = nil
            dockIconArmed = false
            dockIconWatcher?.onClick = { [weak self] in self?.dockIconClicked() }
            scheduleDockIconCheck()
        }
    }
    /// The rule applies: the current profile has no open window.
    private var dockIconArmed = false
    /// While the Dock icon rule applies, another profile's window coming to the front may be the icon's doing,
    /// and not a change of profile (#44 leaves the sidebar alone then).
    var watchesDockIcon: Bool { isOn && dockIconArmed }
    private var dockIconClickAt: Date?
    private var dockIconCheck: DispatchWorkItem?
    /// A window of another profile came to the front while the rule applied, with no click yet: its change
    /// waits `DockIconRule.lateClick` for a click reported after it.
    private var lateClick: (work: DispatchWorkItem, front: Front, at: Date)?
    /// Where the current profile's window last was, for the window the Dock icon opens.
    private var closedFrame: CGRect?

    private var workspaceTokens: [NSObjectProtocol] = []

    init(host: SafariProfiles, settings: AppSettings, tracker: SafariTracker, reader: ProfileReader, minimizer: WindowMinimizer,
         fileURL: URL = MinimizedWindowsFile.defaultURL) {
        self.host = host
        self.settings = settings
        self.tracker = tracker
        self.reader = reader
        self.minimizer = minimizer
        self.fileURL = fileURL
    }

    // MARK: - Lifecycle

    /// Call from SafariProfiles.start, before the docked window is first reported.
    func start() {
        minimizer.onListChanged = { [weak self] list in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.listChanged(list) }
            }
        }
        loadFile()
        observeSetting()
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // The tracker reads the front window again when the desktop changes; look once it has.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.reconsiderFront() }
            }
        })

        guard isOn, let app = tracker.app, !app.isTerminated else { return }
        if let launched = app.launchDate, Date().timeIntervalSince(launched) < Self.safariJustLaunched {
            // Both starting together, at login say: wait for Safari as when it launches.
            safariLaunched()
        } else {
            // Login, an update, after a crash: right away, which catches windows opened meanwhile.
            deferred = (.start, nil)
        }
    }

    /// The saved list, at launch. For the same Safari its window numbers still apply; after a restart of
    /// Safari it's matched by UUID at the first sweep.
    private func loadFile() {
        guard let file = MinimizedWindowsFile.load(from: fileURL) else { return }
        list = file.list
        let pid = tracker.app.flatMap { $0.isTerminated ? nil : $0.processIdentifier }
        let sameSafari = pid != nil && file.safariProcessIdentifier == pid
        if sameSafari, let id = file.currentProfile, host.profiles.contains(where: { $0.id == id }) {
            currentProfileID = id
        }
        let minimizer = minimizer
        let saved = file.list
        reader.queue.async { minimizer.load(saved, sameSafari: sameSafari) }
        log.notice("minimized windows: \(saved.windows.count) on the saved list, for \(sameSafari ? "the Safari running now" : "a Safari that has quit since", privacy: .public)")
    }

    /// Writes the list now if a change is waiting to be saved. For when the app quits.
    func saveIfNeeded() {
        guard saveWork != nil else { return }
        save()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func save() {
        saveWork?.cancel()
        saveWork = nil
        let pid = tracker.app.flatMap { $0.isTerminated ? nil : $0.processIdentifier }
        let file = MinimizedWindowsFile(safariProcessIdentifier: pid, currentProfile: currentProfileID, windows: list.windows)
        do {
            try MinimizedWindowsFile.save(file, to: fileURL)
        } catch {
            log.error("could not save minimized-windows.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func listChanged(_ new: MinimizedList) {
        guard new != list else { return }
        list = new
        scheduleSave()
    }

    // MARK: - The setting

    private func observeSetting() {
        withObservationTracking {
            _ = settings.minimizesOtherProfiles
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.settingChanged()
                    self?.observeSetting()
                }
            }
        }
    }

    private func settingChanged() {
        let minimizer = minimizer
        if isOn {
            // Windows already minimized count as the user's.
            log.notice("minimizing other profiles' windows: turned on")
            reader.queue.async { minimizer.clear() }
            list = MinimizedList()
            scheduleSave()
            deferred = nil
            // If Safari isn't running, or no profile window has been in front yet, it waits until one is.
            wantSweep(.setting, left: nil)
            scheduleDockIconCheck()
            return
        }
        log.notice("minimizing other profiles' windows: turned off; bringing back the \(self.list.windows.count) windows on the list")
        deferred = nil
        cancelLateClick()
        setDockIconRule(applies: false)
        let generation = minimizer.supersede()
        guard let app = host.application else {
            reader.queue.async { minimizer.clear() }
            return
        }
        let resolve = host.makeResolver()
        let current = currentProfileID
        reader.queue.async { [weak self] in
            minimizer.restoreAll(application: app.element, current: current, resolve: resolve, generation: generation) { outcome in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.sweepFinished(outcome) }
                }
            }
        }
    }

    // MARK: - The front window

    /// Remembers where the current profile's window was, from the tracker's last read of the window docked
    /// before: if it closed, a window the Dock icon opens goes there. Call before the docked window's
    /// profile is forgotten.
    func dockedWindowChanging(from previous: WindowReading, profile: UUID?) {
        guard let profile, profile == currentProfileID, let frame = previous.frame, !previous.isFullScreen else { return }
        closedFrame = frame
    }

    /// The docked window's profile, once read: `id` is nil for a private window, one whose profile can't be
    /// told, or no window. `isFinal`: not a toolbar Safari hasn't answered for yet.
    func frontResolved(_ id: UUID?, number: Int?, isFinal: Bool) {
        guard isFinal else { return }
        let front = Front(number: number, profile: id)
        guard front != lastFront else { return }
        lastFront = front
        cancelLateClick()
        if id == nil {
            // The last window closed, say: the Dock icon rule may apply now.
            scheduleDockIconCheck()
        }
        defer { checkSafariStarted() }
        let onShownSpace = number.map { tracker.isOnActiveSpace(windowNumber: $0) } ?? true
        let resolution: ProfileResolution = id.map { .profile($0) } ?? .noProfile
        guard let next = MinimizeRules.currentProfile(currentProfileID, front: resolution, onShownSpace: onShownSpace),
              next != currentProfileID else {
            runDeferred()
            return
        }
        if let inFlight = switchInFlight, inFlight.reason == .dockIcon {
            // The window macOS brought out, while the new one is on its way: not a change of profile.
            return
        }
        if isOn, dockIconArmed {
            let now = Date()
            if DockIconRule.broughtByClick(windowProfile: resolution, current: currentProfileID, clickAt: dockIconClickAt, windowAt: now) {
                dockIconBroughtOut(front)
                return
            }
            // The click may be reported after the window: wait for it a moment before calling it a change.
            let work = DispatchWorkItem { [weak self] in
                guard let self, let pending = self.lateClick else { return }
                self.lateClick = nil
                self.changeCurrent(to: next, front: pending.front.number)
            }
            lateClick = (work, front, now)
            DispatchQueue.main.asyncAfter(deadline: .now() + DockIconRule.lateClick, execute: work)
            return
        }
        changeCurrent(to: next, front: number)
    }

    /// Looks at the front window again when the desktop changes: going to a desktop where a Safari window
    /// is in front is a change of profile like any other.
    private func reconsiderFront() {
        guard let front = lastFront, front.profile != nil, front.profile != currentProfileID else { return }
        lastFront = nil
        frontResolved(front.profile, number: front.number, isFinal: true)
    }

    private func changeCurrent(to id: UUID, front: Int?) {
        let left = currentProfileID
        currentProfileID = id
        if isOn {
            log.notice("the current profile is now \(self.position(id), privacy: .public) (was \(left.map(self.position) ?? "none", privacy: .public))")
            scheduleSave()
            scheduleDockIconCheck()
        }
        guard switchInFlight == nil else { return }
        wantSweep(.change, left: left)
    }

    // MARK: - Sweeps

    /// A sweep for the current profile, now or once it can run.
    private func wantSweep(_ reason: MinimizeReason, left: UUID?) {
        guard isOn else {
            deferred = nil
            return
        }
        // A start or the setting waiting for this keeps its reason.
        let reason = deferred?.reason ?? reason
        let left = left ?? deferred?.left
        guard switchInFlight == nil, !safariStarting, let current = currentProfileID, let app = host.application else {
            deferred = (reason, left)
            return
        }
        deferred = nil
        sweptFor = current
        let generation = minimizer.supersede()
        let sweep = makeSweep(reason, current: current, left: left, front: lastFront?.number, application: app.element)
        let minimizer = minimizer
        reader.queue.async { minimizer.sweep(sweep, generation: generation) }
    }

    private func runDeferred() {
        guard let deferred else { return }
        wantSweep(deferred.reason, left: deferred.left)
    }

    private func makeSweep(_ reason: MinimizeReason, current: UUID, left: UUID?, front: Int?, application: AXUIElement) -> WindowMinimizer.Sweep {
        WindowMinimizer.Sweep(
            application: application, current: current, left: left, front: front, reason: reason,
            resolve: host.makeResolver(),
            completion: { [weak self] outcome in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.sweepFinished(outcome) }
                }
            }
        )
    }

    private func sweepFinished(_ outcome: WindowMinimizer.Outcome) {
        logOutcome(outcome)
        if outcome.reason != .settingOff, let windows = outcome.windows, !outcome.superseded {
            setDockIconRule(applies: DockIconRule.applies(isOn: isOn, current: currentProfileID, windows: windows))
        }
    }

    /// What was minimized and brought back, as counts and profile positions, why, and how long it took.
    /// Never titles or names.
    private func logOutcome(_ outcome: WindowMinimizer.Outcome) {
        func positions(_ ids: [UUID]) -> String {
            ids.isEmpty ? "" : " (profile \(ids.map(position).joined(separator: " ")))"
        }
        var notes: [String] = []
        if let matched = outcome.matched { notes.append("saved list matched: \(matched)") }
        if outcome.closed > 0 { notes.append("\(outcome.closed) on the list had closed") }
        if outcome.broughtBackByUser > 0 { notes.append("\(outcome.broughtBackByUser) on the list the user brought back") }
        if outcome.notMinimized > 0 { notes.append("\(outcome.notMinimized) didn't minimize") }
        if outcome.notRestored > 0 { notes.append("\(outcome.notRestored) didn't come back") }
        if outcome.raisedFrontAgain { notes.append("raised the front window again") }
        if outcome.incompleteRead { notes.append("Safari didn't answer for every window") }
        if outcome.superseded { notes.append("stopped by a newer change") }
        let target = outcome.current.map { " for profile \(position($0))" } ?? ""
        let line = "minimized \(outcome.minimized.count)\(positions(outcome.minimized)), brought back \(outcome.restored.count)\(positions(outcome.restored))\(target) in \(outcome.milliseconds) ms, because \(outcome.reason.rawValue)\(notes.isEmpty ? "" : "; " + notes.joined(separator: "; ")); \(list.windows.count) on the list"
        if outcome.minimized.isEmpty && outcome.restored.isEmpty && notes.isEmpty {
            log.info("\(line, privacy: .public)")
        } else {
            log.notice("\(line, privacy: .public)")
        }
    }

    /// A profile's position in the bar, for the log.
    private func position(_ id: UUID) -> String {
        host.profiles.firstIndex { $0.id == id }.map(String.init) ?? "?"
    }

    // MARK: - Switches

    /// A switch to `profile` is starting (a button, the dropdown, the Dock icon, a closed tab reopening): what
    /// it sweeps once its window is main, with the generation, and a token for `switchFinished`. No sweep with
    /// the setting off, or while Safari starts.
    func switchStarting(to profile: UUID, reason: MinimizeReason) -> (sweep: WindowMinimizer.Sweep?, generation: Int, token: Int) {
        // A switch is a change: a sweep in progress stops before its next window.
        let generation = minimizer.supersede()
        switchToken += 1
        let left = reason == .dockIcon ? nil : currentProfileID
        let broughtOut = reason == .dockIcon ? lastFront : nil
        switchInFlight = SwitchInFlight(token: switchToken, profile: profile, left: left, reason: reason, broughtOut: broughtOut)
        guard isOn, !safariStarting, let app = host.application else {
            return (nil, generation, switchToken)
        }
        sweptFor = profile
        let sweep = makeSweep(reason, current: profile, left: left, front: nil, application: app.element)
        return (sweep, generation, switchToken)
    }

    /// A switch is done. Once its window was in front, its profile is current. A change made meanwhile, or a
    /// switch that didn't get its window in front, is swept for now.
    func switchFinished(token: Int, profile: UUID, succeeded: Bool) {
        guard let inFlight = switchInFlight, inFlight.token == token else { return }
        switchInFlight = nil
        if succeeded {
            if currentProfileID != profile {
                let left = currentProfileID
                currentProfileID = profile
                if isOn {
                    log.notice("the current profile is now \(self.position(profile), privacy: .public) (was \(left.map(self.position) ?? "none", privacy: .public))")
                    scheduleSave()
                }
            }
        } else {
            // Its sweep runs only once its window is main.
            if sweptFor == inFlight.profile {
                sweptFor = nil
            }
            if let broughtOut = inFlight.broughtOut, let id = broughtOut.profile, id != currentProfileID {
                // The Dock icon's window didn't come: the window macOS brought out stays, as a change of profile.
                changeCurrent(to: id, front: broughtOut.number)
                return
            }
        }
        scheduleDockIconCheck()
        if let current = currentProfileID, current != sweptFor || deferred != nil {
            wantSweep(.change, left: inFlight.left)
        }
    }

    // MARK: - Windows opening, Safari starting and quitting

    /// One of Safari's Accessibility notifications.
    func notified(_ name: String) {
        switch name {
        case kAXWindowCreatedNotification:
            lastWindowCreatedAt = Date()
            if safariStarting {
                scheduleStartCheck(after: Self.startQuiet)
            }
            scheduleDockIconCheck()
        case kAXFocusedWindowChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
             kAXUIElementDestroyedNotification:
            scheduleDockIconCheck()
        default:
            break
        }
    }

    /// A window has appeared and its profile has been read. One that comes to the front is a change of
    /// profile; one of another profile that stays behind (History → Reopen All Windows from Last Session, say)
    /// is decided once it has settled.
    func windowAppeared(number: Int?, profile: ProfileResolution) {
        guard isOn, let number, let id = profile.profileID, id != currentProfileID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + ProfileReader.settleTime) { [weak self] in
            guard let self, self.isOn, self.lastFront?.number != number, self.currentProfileID != id else { return }
            self.log.notice("a window of profile \(self.position(id), privacy: .public) opened behind the front one")
            self.wantSweep(.openedBehind, left: nil)
        }
    }

    /// Safari launched while Side Tabs was running.
    func safariLaunched() {
        safariStarting = true
        lastWindowCreatedAt = Date()
        lastFront = nil
        scheduleStartCheck(after: Self.startQuiet)
    }

    private func scheduleStartCheck(after delay: TimeInterval) {
        startCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startCheck = nil
            self?.checkSafariStarted()
        }
        startCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Once Safari stops opening windows (none new for `startQuiet`) and the front window's profile is known.
    private func checkSafariStarted() {
        guard safariStarting else { return }
        let quiet = Date().timeIntervalSince(lastWindowCreatedAt)
        guard quiet >= Self.startQuiet else {
            if startCheck == nil {
                scheduleStartCheck(after: Self.startQuiet - quiet + 0.05)
            }
            return
        }
        // Until a profile window is in front, frontResolved looks again.
        guard isOn, let front = lastFront, let id = front.profile else { return }
        safariStarting = false
        if currentProfileID != id {
            log.notice("the current profile is now \(self.position(id), privacy: .public), the front window's once Safari started")
            currentProfileID = id
        }
        deferred = nil
        wantSweep(.safariStarted, left: nil)
        scheduleDockIconCheck()
    }

    func safariQuit() {
        safariStarting = false
        startCheck?.cancel()
        startCheck = nil
        lastFront = nil
        switchInFlight = nil
        deferred = nil
        cancelLateClick()
        setDockIconRule(applies: false)
        // The list waits to be matched by UUID against the next Safari's windows; the file keeps it meanwhile.
        let minimizer = minimizer
        reader.queue.async { minimizer.safariQuit() }
    }

    // MARK: - Reopening a closed tab

    /// With the setting on, a closed tab of another profile reopens after a switch to that profile, the way
    /// its button switches: Safari's own way of bringing that profile's window forward may not bring back a
    /// minimized window. `profileKey` is the profile of the window cleanup picked, as its copy's snapshots
    /// carry it. Says whether a switch started; `then` runs on the main thread once it's done, with whether
    /// the profile's window came to the front.
    func switchBeforeReopening(profileKey: String?, then: @escaping (Bool) -> Void) -> Bool {
        guard isOn else { return false }
        let key = ProfileKey(snapshotProfile: profileKey)
        guard let profile = host.profiles.first(where: { $0.key == key }), profile.id != currentProfileID else { return false }
        log.notice("reopening a closed tab of profile \(self.position(profile.id), privacy: .public): switching to it first")
        return host.beginSwitch(to: profile, reason: .switched, then: then)
    }

    // MARK: - The Dock icon

    private func scheduleDockIconCheck() {
        guard isOn else {
            setDockIconRule(applies: false)
            return
        }
        dockIconCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dockIconCheck = nil
            self?.checkDockIconRule()
        }
        dockIconCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Reads Safari's windows off the main thread, and arms or disarms the watcher.
    private func checkDockIconRule() {
        guard isOn, let current = currentProfileID, let app = host.application else {
            setDockIconRule(applies: false)
            return
        }
        let resolve = host.makeResolver()
        let minimizer = minimizer
        reader.queue.async { [weak self] in
            let windows = minimizer.readWindows(application: app.element, resolve: resolve).windows
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.currentProfileID == current else { return }
                    self.setDockIconRule(applies: DockIconRule.applies(isOn: self.isOn, current: current, windows: windows))
                }
            }
        }
    }

    private func setDockIconRule(applies: Bool) {
        guard applies != dockIconArmed else { return }
        dockIconArmed = applies
        dockIconClickAt = nil
        if applies {
            dockIconWatcher?.arm()
            log.notice("the current profile has no open window: watching for a click on Safari's Dock icon\(self.dockIconWatcher == nil ? " (no watcher yet)" : "", privacy: .public)")
        } else {
            dockIconWatcher?.disarm()
            cancelLateClick()
            log.notice("no longer watching for a click on Safari's Dock icon")
        }
    }

    private func dockIconClicked() {
        guard isOn, dockIconArmed else { return }
        dockIconClickAt = Date()
        log.notice("a click on Safari's Dock icon")
        // The window it brought out came first.
        if let pending = lateClick, DockIconRule.broughtByClick(windowProfile: pending.front.profile.map { .profile($0) } ?? .noProfile,
                                                                 current: currentProfileID, clickAt: dockIconClickAt, windowAt: pending.at) {
            pending.work.cancel()
            lateClick = nil
            dockIconBroughtOut(pending.front)
        }
    }

    private func cancelLateClick() {
        lateClick?.work.cancel()
        lateClick = nil
    }

    /// A click on the Dock icon brought out another profile's window: a window opens in the current profile
    /// instead (or one the user minimized comes back, as a switch would), where the closed one was, and the
    /// window macOS brought out goes back into the Dock once it's in front (the switch's sweep minimizes it).
    private func dockIconBroughtOut(_ front: Front) {
        let clickAt = dockIconClickAt
        dockIconClickAt = nil
        guard let current = currentProfileID, let profile = host.profiles.first(where: { $0.id == current }),
              let other = front.profile else { return }
        let onList = front.number.map(list.contains) ?? false
        log.notice("the Dock icon brought out a window of profile \(self.position(other), privacy: .public) (\(onList ? "one Side Tabs minimized" : "not on the list: Safari may have opened it", privacy: .public)); a window of profile \(self.position(current), privacy: .public) comes instead")
        // Timed from the click on the icon, not from the sidebar's last press.
        if !host.beginSwitch(to: profile, reason: .dockIcon, frame: closedFrame, clickAt: clickAt) {
            changeCurrent(to: other, front: front.number)
        }
    }
}
