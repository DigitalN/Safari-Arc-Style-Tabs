import AppKit
import Observation
import SafariServices
import os.log

/// Safari's profiles for the sidebar's bottom bar (#33): one button per profile, which one the front
/// window is in, switching in place, and whether Side Tabs is off in the front window's profile.
///
/// - **The list** comes from File → New Window, read at launch, when Safari launches, when a window of
///   a profile the list doesn't have appears, and when Settings closes. No timer. It's kept in
///   profiles.json, so the bar is right at launch.
/// - **The front window's profile** comes from its toolbar's profile button, which is there in every
///   profile, including ones where Side Tabs is off, and in no private window.
/// - **Each profile's extension copy** is learned when the docked window, whose profile is known, is
///   listed by exactly one copy.
///
/// Nothing here waits for Safari: ProfileReader and ProfileSwitcher do their Accessibility calls on
/// their own queue, and this class uses the answers when they arrive.
@Observable
final class SafariProfiles {
    /// In Safari's order.
    private(set) var profiles: [SafariProfile]
    /// The docked window's profile. Nil for a private window, and while it isn't known.
    private(set) var dockedProfileID: UUID?
    /// The front window's profile while Side Tabs is off in it: the sidebar shows a row to turn it on.
    private(set) var profileToTurnOn: SafariProfile?
    /// A switch that Safari hasn't shown yet. Its button is highlighted meanwhile.
    private var pendingSwitch: PendingSwitch?

    private struct PendingSwitch: Equatable {
        let id: UUID
        let at: Date
        /// After this, the highlight goes back to following Safari.
        static let lifetime: TimeInterval = 3
    }

    /// The button to highlight: the profile being switched to, else the front window's.
    var highlightedID: UUID? { pendingSwitch?.id ?? dockedProfileID }

    /// With one profile, only the + shows.
    var showsButtons: Bool { profiles.count > 1 }

    @ObservationIgnored private let tracker: SafariTracker
    @ObservationIgnored private let store: TabStore
    @ObservationIgnored private let reader = ProfileReader()
    @ObservationIgnored private lazy var switcher = ProfileSwitcher(reader: reader)
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "profiles")

    /// When Side Tabs started listening. Copies already running send a heartbeat within 5 s, so until
    /// a little after that, silence from a profile's copy says nothing.
    @ObservationIgnored private var startedAt = Date()
    private static let listenGrace: TimeInterval = 6

    // The docked window, as last read.
    @ObservationIgnored private var dockedWindow: AXUIElement?
    @ObservationIgnored private var dockedNumber: Int?
    @ObservationIgnored private var dockedToolbar: ToolbarProfile = .unknown
    @ObservationIgnored private var dockedOpenSince: Date?
    /// `dockedProfileID` is the docked window's. False from a change of window until the new one's
    /// toolbar has been read: meanwhile the highlight stays, but nothing is learned or decided from it.
    @ObservationIgnored private var dockedResolved = false
    @ObservationIgnored private var toolbarRetries = 0
    /// When each window was first seen, by number, for the off rule.
    @ObservationIgnored private var windowFirstSeen: [Int: Date] = [:]
    /// The position of the menu item with ⌘N, from a menu read made while `window` was docked.
    @ObservationIgnored private var newWindowShortcut: (window: Int, position: Int)?
    /// Toolbar profiles already looked up in the menu since it last changed, so a name the menu
    /// doesn't have doesn't make Side Tabs read it on every window change.
    @ObservationIgnored private var lookedUp: Set<String> = []
    /// Settings (or another window that isn't a browser window) had focus last time Safari said.
    @ObservationIgnored private var settingsFocused = false
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var offCheck: DispatchWorkItem?
    @ObservationIgnored private var workspaceTokens: [NSObjectProtocol] = []

    init(tracker: SafariTracker, store: TabStore, fileURL: URL = ProfilesFile.defaultURL) {
        self.tracker = tracker
        self.store = store
        self.fileURL = fileURL
        profiles = ProfilesFile.load(from: fileURL)
    }

    // MARK: - Lifecycle

    /// Call after the tracker has started.
    func start() {
        startedAt = Date()
        tracker.onWindowChange = { [weak self] in self?.dockedWindowChanged() }
        tracker.onNotification = { [weak self] name, element in self?.safariNotified(name, element: element) }

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SafariTracker.safariBundleID else { return }
            MainActor.assumeIsolated {
                // The tracker attaches half a second after launch; the menus take a moment longer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.readMenu(because: "Safari launched", attempts: 5, readingWindows: true)
                }
            }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SafariTracker.safariBundleID else { return }
            MainActor.assumeIsolated { self?.safariQuit() }
        })

        observeStore()
        readMenu(because: "launch", attempts: 3, readingWindows: true)
        dockedWindowChanged()
    }

    /// Writes profiles.json now if a change is waiting to be saved. For when the app quits.
    func saveIfNeeded() {
        guard saveWork != nil else { return }
        save()
    }

    private func save() {
        saveWork?.cancel()
        saveWork = nil
        do {
            try ProfilesFile.save(profiles, to: fileURL)
        } catch {
            log.error("could not save profiles.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func safariQuit() {
        let reader = reader
        reader.queue.async { reader.forget() }
        windowFirstSeen = [:]
        newWindowShortcut = nil
        settingsFocused = false
        pendingSwitch = nil
    }

    /// Changes to the store's snapshots or the docked window's title can tell which copy lists the
    /// docked window, and whether Side Tabs is on in its profile.
    private func observeStore() {
        withObservationTracking {
            _ = store.snapshots
            _ = store.dockedWindowTitle
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let id = self.dockedProfileID, self.dockedResolved {
                        self.learn(about: id)
                    } else if case .profile = self.dockedToolbar {
                        // Profiles sharing a name may now be told apart by the copy listing the window.
                        self.resolveDocked()
                    }
                    self.evaluateOff()
                    self.observeStore()
                }
            }
        }
    }

    // MARK: - The menu

    private var application: (element: AXUIElement, pid: pid_t)? {
        guard tracker.isTrusted, let app = tracker.app, !app.isTerminated else { return nil }
        return (AXUIElementCreateApplication(app.processIdentifier), app.processIdentifier)
    }

    /// Reads File → New Window off the main thread. `readingWindows` also reads every window's
    /// profile, which is kept, so the first switch after a launch doesn't have to.
    private func readMenu(because reason: String, attempts: Int = 1, readingWindows: Bool = false) {
        guard let element = application?.element else { return }
        let window = dockedNumber
        let reader = reader
        reader.queue.async { [weak self] in
            let reading = reader.readMenu(application: element)
            if reading != nil, readingWindows {
                _ = reader.windows(application: element)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let reading else {
                        if attempts > 1 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                                self?.readMenu(because: reason, attempts: attempts - 1, readingWindows: readingWindows)
                            }
                        } else {
                            self.log.notice("couldn't read File → New Window (\(reason, privacy: .public))")
                        }
                        return
                    }
                    self.menuRead(reading, because: reason, window: window)
                }
            }
        }
    }

    private func menuRead(_ reading: ProfileReader.MenuReading, because reason: String, window: Int?) {
        let updated = ProfileList.reconcile(remembered: profiles, menu: reading.profiles)
        let changed = updated != profiles
        if changed {
            profiles = updated
            lookedUp = []
            scheduleSave()
        }
        let shortcut = reading.profiles.firstIndex(where: \.hasNewWindowShortcut)
        if let window, let shortcut {
            newWindowShortcut = (window, shortcut)
        }
        let defaultPosition = reading.profiles.firstIndex(where: \.isDefault).map(String.init) ?? "none"
        log.notice("read File → New Window (\(reason, privacy: .public)) in \(reading.milliseconds) ms: \(reading.profiles.count) profiles, default at \(defaultPosition, privacy: .public), ⌘N at \(shortcut.map(String.init) ?? "none", privacy: .public)\(changed ? "; the list changed" : "", privacy: .public)")
        resolveDocked()
    }

    /// Reads the menu once for a toolbar profile it couldn't place.
    private func lookUp(_ toolbar: ToolbarProfile, because reason: String) {
        guard case .profile(let name, let symbol) = toolbar else { return }
        guard lookedUp.insert("\(name)\u{1}\(symbol ?? "")").inserted else { return }
        readMenu(because: reason)
    }

    // MARK: - The docked window

    private func dockedWindowChanged() {
        let window = tracker.window
        dockedWindow = window
        dockedNumber = nil
        dockedToolbar = .unknown
        dockedResolved = false
        toolbarRetries = 0
        guard let window else {
            setDocked(nil)
            return
        }
        readDockedToolbar(window)
    }

    private func readDockedToolbar(_ window: AXUIElement) {
        guard tracker.isTrusted else { return }
        let reader = reader
        reader.queue.async { [weak self] in
            let (number, toolbar) = reader.toolbarProfile(of: window)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let docked = self.dockedWindow, CFEqual(docked, window) else { return }
                    self.dockedToolbarRead(toolbar, number: number, window: window)
                }
            }
        }
    }

    private func dockedToolbarRead(_ toolbar: ToolbarProfile, number: Int?, window: AXUIElement) {
        dockedNumber = number
        dockedToolbar = toolbar
        let firstSeen: Date
        if let number {
            firstSeen = windowFirstSeen[number] ?? Date()
            windowFirstSeen[number] = firstSeen
        } else {
            firstSeen = Date()
        }
        dockedOpenSince = max(firstSeen, startedAt.addingTimeInterval(Self.listenGrace))
        // Right after a window opens, Safari may not have added the profile button yet (up to 50 ms
        // in #28), or may not have answered: look again shortly.
        let retry = toolbar == .unknown ? 5 : toolbar == .noProfileButton ? 2 : 0
        if toolbarRetries < retry {
            toolbarRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let docked = self.dockedWindow, CFEqual(docked, window) else { return }
                self.readDockedToolbar(window)
            }
        }
        resolveDocked()
    }

    /// The docked window's title, as the tracker last read it. Taken from the tracker rather than the
    /// store, so it can't be the previous window's while the store catches up.
    private var dockedTitle: String? {
        guard let window = dockedWindow, let tracked = tracker.window, CFEqual(window, tracked) else { return nil }
        return tracker.title(of: window)
    }

    private func resolveDocked() {
        let shortcut = newWindowShortcut.flatMap { $0.window == dockedNumber ? $0.position : nil }
        let resolution = ProfileRules.resolve(dockedToolbar, windowTitle: dockedTitle, profiles: profiles, copyWindows: copyWindows, newWindowShortcut: shortcut)
        switch resolution {
        case .profile(let id):
            learn(about: id)
            setDocked(id)
        case .unknownName:
            setDocked(nil)
            lookUp(dockedToolbar, because: "a window of a profile the list doesn't have")
        case .ambiguous:
            setDocked(nil)
            lookUp(dockedToolbar, because: "a window whose profile shares its name")
        case .noProfile:
            setDocked(nil)
        }
    }

    private func setDocked(_ id: UUID?) {
        dockedResolved = true
        if dockedProfileID != id {
            dockedProfileID = id
            let position = id.flatMap { id in profiles.firstIndex { $0.id == id } }
            switch (position, dockedToolbar) {
            case (let position?, _):
                log.notice("the front window is in profile \(position)")
            case (nil, .noProfileButton):
                log.notice("the front window is in no profile (a private window)")
            default:
                log.notice("the front window's profile isn't known yet")
            }
        }
        if let pending = pendingSwitch, pending.id == id {
            pendingSwitch = nil
        }
        evaluateOff()
    }

    /// What the docked window, now known to be in profile `id`, tells about that profile: its symbol,
    /// and which extension copy is its.
    private func learn(about id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var updated = profiles
        if case .profile(_, let symbol?) = dockedToolbar, updated[index].symbol != symbol {
            updated[index].symbol = symbol
            log.notice("profile \(index) has the symbol \(symbol, privacy: .public)")
        }
        if let key = ProfileRules.keyToLearn(for: updated[index], windowTitle: dockedTitle, in: copyWindows, profiles: updated),
           ProfileList.assign(key, to: id, in: &updated) {
            log.notice("profile \(index) is the extension copy with profile \(key.rawValue.prefix(8), privacy: .public)")
        }
        if updated != profiles {
            profiles = updated
            scheduleSave()
        }
    }

    // MARK: - Side Tabs off in a profile

    /// Every window the extension copies list, from their snapshots.
    private var copyWindows: [CopyWindow] {
        store.snapshots.values.flatMap { snapshot in
            let key = ProfileKey(snapshotProfile: snapshot.profile)
            return snapshot.windows.map { CopyWindow(key: key, incognito: $0.incognito, activeTitle: $0.tabs.first(where: \.active)?.title) }
        }
    }

    /// The extension copies sending heartbeats.
    ///
    /// #31 adds a way to ask the store whether a copy has gone quiet (Side Tabs turned off in its
    /// profile, or replaced after a reinstall). Until it's merged, every copy with a snapshot counts
    /// as live; with it, leave out the quiet ones here. That's what lets an "on" profile become "off".
    private var liveInstances: Set<String> {
        Set(store.snapshots.keys)
    }

    private func evaluateOff() {
        // While the docked window's profile is being read, keep what's shown.
        guard dockedResolved else { return }
        offCheck?.cancel()
        offCheck = nil
        var off: SafariProfile?
        if profiles.count > 1, let id = dockedProfileID, let since = dockedOpenSince,
           let profile = profiles.first(where: { $0.id == id }) {
            let title = dockedTitle
            let live = liveInstances
            let copies = store.snapshots.values.map { snapshot in
                CopyState(
                    key: ProfileKey(snapshotProfile: snapshot.profile),
                    isLive: live.contains(snapshot.instance),
                    reportsWindow: snapshot.windows.contains {
                        !$0.incognito && ProfileRules.fits(windowTitle: title, profileName: profile.name, activeTitle: $0.tabs.first(where: \.active)?.title)
                    }
                )
            }
            let openFor = Date().timeIntervalSince(since)
            if ProfileRules.isOff(profile, profiles: profiles, windowOpenFor: openFor, copies: copies) {
                off = profile
            } else if openFor < ProfileRules.offAfter {
                // Look again when the window has been open long enough.
                let work = DispatchWorkItem { [weak self] in self?.evaluateOff() }
                offCheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + ProfileRules.offAfter - openFor + 0.05, execute: work)
            }
        }
        guard off != profileToTurnOn else { return }
        let before = profileToTurnOn?.id
        profileToTurnOn = off
        guard off?.id != before else { return }
        if let off, let position = profiles.firstIndex(where: { $0.id == off.id }) {
            log.notice("Side Tabs counts as off in profile \(position): no live copy of it, and none lists its window")
        } else {
            log.notice("Side Tabs no longer counts as off in the front window's profile")
        }
    }

    // MARK: - Actions

    /// Switches to `profile` in place. On mouse-down; does nothing for the current profile, or
    /// without Accessibility access.
    func select(_ profile: SafariProfile) {
        guard let app = application,
              let position = profiles.firstIndex(where: { $0.id == profile.id }),
              profile.id != highlightedID else { return }
        let clickAt = store.lastPointerDown?() ?? Date()
        let pending = PendingSwitch(id: profile.id, at: Date())
        pendingSwitch = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + PendingSwitch.lifetime) { [weak self] in
            guard let self, self.pendingSwitch == pending else { return }
            self.pendingSwitch = nil
            self.log.notice("the switch to profile \(position) didn't show in time; the highlight follows Safari again")
        }

        let docked = tracker.window
        let frame = docked.flatMap { tracker.isFullScreen($0) ? nil : tracker.frame(of: $0) }
        let known = profiles
        let windows = copyWindows
        let request = ProfileSwitcher.Request(
            application: app.element,
            processIdentifier: app.pid,
            profile: profile,
            position: position,
            frame: frame,
            resolve: { toolbar, title in
                ProfileRules.resolve(toolbar, windowTitle: title, profiles: known, copyWindows: windows)
            }
        )
        log.notice("switching to profile \(position)")
        switcher.switchTo(request, clickAt: clickAt) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.switchFinished(outcome, pending: pending, position: position)
                }
            }
        }
    }

    private func switchFinished(_ outcome: ProfileSwitcher.Outcome, pending: PendingSwitch, position: Int) {
        switch outcome {
        case .raised(let milliseconds, let minimized):
            log.notice("switched to profile \(position): its window was Safari's main window \(milliseconds) ms after the click\(minimized ? " (it was minimized)" : "", privacy: .public)")
        case .opened(let milliseconds):
            log.notice("switched to profile \(position): it had no window; a new one appeared \(milliseconds) ms after the click")
        case .superseded:
            break
        case .menuOutOfDate:
            log.notice("File → New Window has no item for profile \(position); reading it again")
            if pendingSwitch == pending { pendingSwitch = nil }
            readMenu(because: "a profile with no item")
        case .failed(let reason):
            log.notice("the switch to profile \(position) failed: \(reason, privacy: .public)")
            if pendingSwitch == pending { pendingSwitch = nil }
        }
    }

    /// The +: Safari's Settings at Profiles, where the user adds a profile. Side Tabs doesn't press
    /// Add Profile itself.
    func newProfile() {
        guard let app = application else { return }
        log.notice("opening Safari → Manage Profiles…")
        switcher.openManageProfiles(application: app.element, processIdentifier: app.pid) { [log] pressed in
            if !pressed {
                log.notice("Manage Profiles… not found in Safari's menu")
            }
        }
    }

    /// The "Turn on Side Tabs for this profile" row: takes the user to where they tick the box.
    func turnOnSideTabs() {
        guard let profile = profileToTurnOn, let position = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        if profile.isDefault {
            // The default profile has no Extensions tab under Profiles; Settings → Extensions is its.
            log.notice("opening Safari's extension settings for the default profile")
            SFSafariApplication.showPreferencesForExtension(withIdentifier: SideTabsBridge.extensionBundleIdentifier) { [log] error in
                if let error {
                    log.error("could not open the extension settings: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
        guard let app = application else { return }
        log.notice("opening the extensions of profile \(position)")
        switcher.showExtensions(of: profile, position: position, profileCount: profiles.count, application: app.element, processIdentifier: app.pid) { [log] problem in
            if let problem {
                log.notice("couldn't open the extensions of profile \(position): \(problem, privacy: .public)")
            }
        }
    }

    // MARK: - Safari's notifications

    private func safariNotified(_ name: String, element: AXUIElement) {
        switch name {
        case kAXWindowCreatedNotification:
            // Read its profile now, so a switch to it later doesn't have to. A window of a profile
            // the list doesn't have means the list is out of date.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.windowAppeared(element)
            }
        case kAXFocusedWindowChangedNotification:
            checkSettingsClosed()
        default:
            break
        }
    }

    private func windowAppeared(_ window: AXUIElement) {
        guard tracker.isTrusted else { return }
        let reader = reader
        reader.queue.async { [weak self] in
            let toolbar = reader.toolbarProfile(of: window).profile
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, case .profile(let name, _) = toolbar, !name.isEmpty,
                          !self.profiles.contains(where: { ProfileIdentifiers.sameName($0.name, name) }) else { return }
                    self.lookUp(toolbar, because: "a window of a profile the list doesn't have")
                }
            }
        }
    }

    /// Profiles are added, renamed and deleted in Settings, so the list is read again when it closes.
    private func checkSettingsClosed() {
        guard let element = application?.element else { return }
        let reader = reader
        reader.queue.async { [weak self] in
            let isBrowser = reader.focusedWindowIsBrowser(application: element)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let isBrowser else { return }
                    if !isBrowser {
                        self.settingsFocused = true
                    } else if self.settingsFocused {
                        self.settingsFocused = false
                        self.readMenu(because: "Settings closed")
                    }
                }
            }
        }
    }
}
