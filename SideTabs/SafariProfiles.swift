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
///
/// "Minimize other profiles' windows" (#42) is MinimizeOtherProfiles', which this tells about the docked
/// window, and whose switches (the Dock icon, a closed tab reopening) run here like the buttons'.
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
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let reader = ProfileReader()
    @ObservationIgnored private lazy var minimizer = WindowMinimizer(reader: reader)
    @ObservationIgnored private lazy var switcher = ProfileSwitcher(reader: reader, minimizer: minimizer)
    /// "Minimize other profiles' windows" (#42).
    @ObservationIgnored private lazy var minimizing = MinimizeOtherProfiles(
        host: self, settings: settings, tracker: tracker, store: store, reader: reader, minimizer: minimizer
    )
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

    // Reading the menu (#40).
    /// When each profile a read lacked, with nothing else showing it, was first missed.
    @ObservationIgnored private var missingSince: [UUID: Date] = [:]
    /// The next read after one that didn't agree with what else is known, and how many came before it.
    @ObservationIgnored private var rereadWork: DispatchWorkItem?
    @ObservationIgnored private var rereadStep = 0
    private static let rereadDelays: [TimeInterval] = [0.5, 1, 2, 4]
    /// A read for when the start-up grace is over, if one is waiting to drop a profile.
    @ObservationIgnored private var graceWork: DispatchWorkItem?
    /// When Safari last launched while Side Tabs was running.
    @ObservationIgnored private var safariLaunchedAt: Date?
    /// For this long after Side Tabs starts or Safari launches, no profile is dropped: the menu and the
    /// extension copies may not all be there yet.
    private static let dropGrace: TimeInterval = 10
    /// The keys of profiles kept because their copy was live while the menu lacked them. When one goes
    /// quiet, the menu is read again.
    @ObservationIgnored private var keysKeptForCopies: Set<ProfileKey> = []

    /// The docked window's tabs from its tab bar, while its profile's copy can't see it (#41).
    @ObservationIgnored let unseenTabs: UnseenWindowTabs

    // What the sidebar shows while a switch's window comes back from the Dock (#44, TabStore.switchPreview).
    /// The newest switch's preview id: a target picked for an older one is ignored.
    @ObservationIgnored private var latestPreview = 0
    /// The docked window when the preview began: another one coming to the front ends it.
    @ObservationIgnored private var previewDockedNumber: Int?
    /// How long after the click a minimized switch target lands: from the Dock's minimize effect (read off the
    /// main thread) until switches have measured it. The sidebar's fade-in ends then.
    @ObservationIgnored private var arrivalEstimate = SwitchPreviewRules.arrivalEstimate(minimizeEffect: nil)
    /// The minimize effect the estimate is for; a new one starts it over.
    @ObservationIgnored private var minimizeEffect: String??
    /// A one-off look when the docked window has been open long enough to call it unseen.
    @ObservationIgnored private var settleCheck: DispatchWorkItem?

    init(tracker: SafariTracker, store: TabStore, settings: AppSettings, fileURL: URL = ProfilesFile.defaultURL) {
        self.tracker = tracker
        self.store = store
        self.settings = settings
        self.fileURL = fileURL
        profiles = ProfilesFile.load(from: fileURL)
        unseenTabs = UnseenWindowTabs(tracker: tracker, store: store)
    }

    // MARK: - Lifecycle

    /// Watches for a click on Safari's Dock icon, for "Minimize other profiles' windows" (#42). Nil until
    /// wired; set it before `start`.
    var dockIconWatcher: (any SafariDockIconWatching)? {
        get { minimizing.dockIconWatcher }
        set { minimizing.dockIconWatcher = newValue }
    }

    /// Call after the tracker has started.
    func start() {
        startedAt = Date()
        minimizing.start()
        store.switchProfileFirst = { [weak self] profile, then in
            self?.minimizing.switchBeforeReopening(profileKey: profile, then: then) ?? false
        }
        tracker.onWindowChange = { [weak self] in self?.dockedWindowChanged() }
        tracker.onNotification = { [weak self] name, element in self?.safariNotified(name, element: element) }

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SafariTracker.safariBundleID else { return }
            MainActor.assumeIsolated {
                self?.safariLaunchedAt = Date()
                self?.minimizing.safariLaunched()
                // The tracker attaches half a second after launch; the menus take a moment longer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.readMenu(because: "Safari launched", attempts: 5)
                }
            }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SafariTracker.safariBundleID else { return }
            MainActor.assumeIsolated { self?.safariQuit() }
        })

        observeStore()
        refreshArrivalEstimate()
        unseenTabs.start()
        readMenu(because: "launch", attempts: 3)
        dockedWindowChanged()
    }

    /// Writes profiles.json, and the list of windows Side Tabs minimized, now if a change is waiting to be
    /// saved. For when the app quits.
    func saveIfNeeded() {
        minimizing.saveIfNeeded()
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
        minimizing.safariQuit()
        store.endSwitchPreview(because: "Safari quit")
        windowFirstSeen = [:]
        newWindowShortcut = nil
        settingsFocused = false
        pendingSwitch = nil
        // Reads made while it quit say nothing; the next launch starts over.
        rereadWork?.cancel()
        rereadWork = nil
        graceWork?.cancel()
        graceWork = nil
        missingSince = [:]
        keysKeptForCopies = []
        safariLaunchedAt = nil
    }

    /// Changes to the store's snapshots or the docked window's title can tell which copy lists the
    /// docked window, and whether Side Tabs is on in its profile.
    private func observeStore() {
        withObservationTracking {
            _ = store.snapshots
            _ = store.dockedWindowTitle
            // A copy going quiet changes no snapshot, but can turn its profile off.
            _ = store.liveInstances
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !self.keysKeptForCopies.isEmpty, !self.keysKeptForCopies.isSubset(of: self.liveKeys) {
                        // A profile the menu lacked was kept for its copy, which has now gone quiet.
                        self.keysKeptForCopies = []
                        self.readMenu(because: "the extension copy of a profile the menu lacked went quiet")
                    }
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

    var application: (element: AXUIElement, pid: pid_t)? {
        guard tracker.isTrusted, let app = tracker.app, !app.isTerminated else { return nil }
        return (AXUIElementCreateApplication(app.processIdentifier), app.processIdentifier)
    }

    /// Reads the File menu and every window's profile, off the main thread, and checks the one against
    /// the other (`menuRead`). `trigger`: something happened that may have changed the profiles, which
    /// starts the reads again from the shortest wait; reads again after one that didn't agree aren't.
    private func readMenu(because reason: String, attempts: Int = 1, trigger: Bool = true, again: Int = 0) {
        guard let app = application else { return }
        if trigger {
            rereadWork?.cancel()
            rereadWork = nil
            rereadStep = 0
        }
        let window = dockedNumber
        let reader = reader
        let element = app.element
        let pid = app.pid
        reader.queue.async { [weak self] in
            let reading = reader.readMenu(application: element)
            // What the windows say, to check the read against. Each window's profile is read once and
            // kept, so this is cheap after the first time, and the first switch after a launch is quick.
            let toolbars = reading != nil ? reader.windows(application: element).map(\.toolbar) : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let label = again > 0 ? "\(reason), read again \(again)" : reason
                    // Safari quit, or quit and launched again, while this was read: it says nothing now.
                    guard let current = self.tracker.app, !current.isTerminated, current.processIdentifier == pid else {
                        self.log.notice("ignoring a read of File → New Window from before Safari quit (\(label, privacy: .public))")
                        return
                    }
                    guard let reading else {
                        if attempts > 1 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                                self?.readMenu(because: reason, attempts: attempts - 1, trigger: false, again: again)
                            }
                        } else {
                            self.log.notice("couldn't read File → New Window (\(label, privacy: .public))")
                            self.scheduleReread(because: reason)
                        }
                        return
                    }
                    self.menuRead(reading, toolbars: toolbars, because: label, baseReason: reason, window: window)
                }
            }
        }
    }

    /// Takes a read of the menu, checked against the open windows and the live extension copies
    /// (`ProfileList.update`): a read that comes up short never takes a button away, and is read again
    /// with back-off; a profile goes only when two reads agree and nothing else shows it.
    private func menuRead(_ reading: ProfileReader.MenuReading, toolbars: [ToolbarProfile], because label: String, baseReason: String, window: Int?) {
        let now = Date()
        let startedAt = max(self.startedAt, safariLaunchedAt ?? .distantPast)
        let starting = now.timeIntervalSince(startedAt) < Self.dropGrace
        let before = profiles
        let update = ProfileList.update(
            before, read: reading.profiles,
            evidence: ProfileEvidence(toolbars: toolbars, liveKeys: liveKeys),
            missingSince: missingSince, now: now, mayDrop: !starting
        )
        missingSince = update.missingSince
        keysKeptForCopies = Set(update.keptForCopies.compactMap { id in before.first { $0.id == id }?.key })
        let changed = update.profiles != before
        if changed {
            profiles = update.profiles
            lookedUp = []
            scheduleSave()
        }

        // ⌘N's item, among the profiles the read listed, as a position in the list shown.
        let shortcut = reading.profiles.firstIndex(where: \.hasNewWindowShortcut)
        if let window, let shortcut {
            let notRead = Set(update.keptForWindows + update.keptForCopies + update.awaitingSecondRead + update.addedFromWindows)
            let listed = profiles.indices.filter { !notRead.contains(profiles[$0].id) }
            if listed.indices.contains(shortcut) {
                newWindowShortcut = (window, listed[shortcut])
            }
        }
        let defaultPosition = reading.profiles.firstIndex(where: \.isDefault).map(String.init) ?? "none"
        log.notice("read File → New Window (\(label, privacy: .public)) in \(reading.milliseconds) ms: \(reading.profiles.count) profiles, default at \(defaultPosition, privacy: .public), ⌘N at \(shortcut.map(String.init) ?? "none", privacy: .public)\(changed ? "; the list changed" : "", privacy: .public)")
        if !update.agrees || reading.profiles.count < before.count {
            func positions(_ ids: [UUID], in list: [SafariProfile]) -> String {
                let found = ids.compactMap { id in list.firstIndex { $0.id == id } }
                return found.isEmpty ? "none" : found.map(String.init).joined(separator: " ")
            }
            log.notice("""
                the read lists fewer profiles than are known (\(before.count) before, \(self.profiles.count) now): \
                kept for open windows: \(positions(update.keptForWindows, in: before), privacy: .public); \
                kept for live extension copies: \(positions(update.keptForCopies, in: before), privacy: .public); \
                kept until a second read agrees: \(positions(update.awaitingSecondRead, in: before), privacy: .public); \
                added from open windows: \(positions(update.addedFromWindows, in: self.profiles), privacy: .public); \
                dropped: \(positions(update.removed, in: before), privacy: .public). \
                File menu: \(reading.shape, privacy: .public)
                """)
        } else {
            // The same, without names, for a live test to see how Safari lays the menu out
            // (`log show --info`).
            log.info("File menu: \(reading.shape, privacy: .public)")
        }

        if update.agrees {
            rereadWork?.cancel()
            rereadWork = nil
            rereadStep = 0
        } else {
            scheduleReread(because: baseReason)
        }
        if !update.awaitingSecondRead.isEmpty, starting, graceWork == nil {
            // Nothing is dropped while starting up; look again once that's over.
            let work = DispatchWorkItem { [weak self] in
                self?.graceWork = nil
                self?.readMenu(because: "after starting up")
            }
            graceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropGrace - now.timeIntervalSince(startedAt) + 0.2, execute: work)
        }
        resolveDocked()
        learnSymbols(from: toolbars)
        countLikeWindows(from: toolbars)
    }

    /// Reads again after a read that didn't agree with what else is known: after 0.5, 1, 2 and 4 s, then
    /// not until something happens that may change the profiles.
    private func scheduleReread(because reason: String) {
        guard rereadWork == nil, rereadStep < Self.rereadDelays.count else { return }
        let delay = Self.rereadDelays[rereadStep]
        rereadStep += 1
        let step = rereadStep
        let work = DispatchWorkItem { [weak self] in
            self?.rereadWork = nil
            self?.readMenu(because: reason, trigger: false, again: step)
        }
        rereadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The profiles of the extension copies sending heartbeats.
    private var liveKeys: Set<ProfileKey> {
        let live = liveInstances
        return Set(store.snapshots.values.filter { live.contains($0.instance) }.map { ProfileKey(snapshotProfile: $0.profile) })
    }

    /// Reads the menu for a toolbar profile the list couldn't place: once per profile until the list
    /// changes. The read is checked against the window, and read again with back-off while they disagree;
    /// a profile windows show that the menu doesn't list is added from what its toolbar says.
    private func lookUp(_ toolbar: ToolbarProfile, because reason: String) {
        guard case .profile(let name, let symbol) = toolbar else { return }
        guard lookedUp.insert("\(name)\u{1}\(symbol ?? "")").inserted else { return }
        readMenu(because: reason)
    }

    // MARK: - The docked window

    private func dockedWindowChanged() {
        // Where the current profile's window was, if it's the one going (#42).
        minimizing.dockedWindowChanging(from: tracker.previousReading, profile: dockedResolved ? dockedProfileID : nil)
        let window = tracker.window
        dockedWindow = window
        dockedNumber = nil
        dockedToolbar = .unknown
        dockedResolved = false
        toolbarRetries = 0
        // Until the new window's profile is read, the store mustn't prefer the previous one's copy.
        tellStoreDockedProfile()
        unseenTabs.dockedWindowChanged(to: window)
        guard let window else {
            setDocked(nil)
            return
        }
        readDockedToolbar(window)
    }

    /// Tells the store the docked window's profile, so it takes the docked window from that profile's copy
    /// rather than going by the copies' focus reports alone (#36).
    private func tellStoreDockedProfile() {
        let key = dockedResolved ? dockedProfileID.flatMap { id in profiles.first { $0.id == id }?.key } : nil
        if store.dockedWindowProfile != key?.rawValue {
            store.dockedWindowProfile = key?.rawValue
        }
        tellStoreWhetherSettled()
    }

    /// Tells the store what it needs to tell a docked window its copy can't see (#41): whether it's private,
    /// and whether it has been open long enough (`ProfileRules.offAfter`, as for the off rule) for its copy to
    /// have reported it. A window opened a moment ago isn't unseen just because its report is on its way.
    private func tellStoreWhetherSettled() {
        settleCheck?.cancel()
        settleCheck = nil
        // A window without a profile button, in a Safari with profiles. Right after a window opens its button
        // may not be there yet, but nothing is decided from this until the window has settled, and by then
        // the toolbar has been read again.
        let isPrivate = dockedResolved && dockedToolbar == .noProfileButton && profiles.count > 1
        if store.dockedWindowIsPrivate != isPrivate {
            store.dockedWindowIsPrivate = isPrivate
        }
        var settled = false
        if dockedResolved, dockedProfileID != nil || isPrivate, let since = dockedOpenSince {
            let openFor = Date().timeIntervalSince(since)
            settled = openFor >= ProfileRules.offAfter
            if !settled {
                let work = DispatchWorkItem { [weak self] in
                    self?.tellStoreWhetherSettled()
                    self?.countLikeWindows()
                }
                settleCheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + ProfileRules.offAfter - openFor + 0.05, execute: work)
            }
        }
        if store.dockedWindowSettled != settled {
            store.dockedWindowSettled = settled
        }
    }

    /// Counts Safari's windows like the docked one (of its profile, or private), for the store to tell a
    /// copy that's behind on a title from one that can't see the window (#41). Each window's profile is read
    /// once and kept, so this is cheap.
    private func countLikeWindows() {
        guard let element = application?.element else { return }
        let reader = reader
        reader.queue.async { [weak self] in
            let toolbars = reader.windows(application: element).map(\.toolbar)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.countLikeWindows(from: toolbars) }
            }
        }
    }

    private func countLikeWindows(from toolbars: [ToolbarProfile]) {
        var count: Int?
        if store.dockedWindowIsPrivate {
            count = toolbars.filter { $0 == .noProfileButton }.count
        } else if let id = dockedProfileID, dockedResolved {
            count = toolbars.filter { ProfileRules.resolve($0, windowTitle: nil, profiles: profiles, copyWindows: []).profileID == id }.count
        }
        if store.dockedLikeWindowCount != count {
            store.dockedLikeWindowCount = count
        }
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
        tellStoreDockedProfile()
        countLikeWindows()
        evaluateOff()
        // Not while a toolbar Safari hasn't answered for yet is being read again.
        let isFinal = dockedWindow == nil || dockedToolbar != .unknown || toolbarRetries >= 5
        settlePreview(id, isFinal: isFinal)
        minimizing.frontResolved(id, number: dockedNumber, isFinal: isFinal)
    }

    /// What the docked window says about the sidebar's guess during a switch (#44): Safari shows the switch's
    /// profile, so the sidebar's own choice takes over once it's that profile's; or another window came to the
    /// front, and the sidebar follows Safari again.
    private func settlePreview(_ id: UUID?, isFinal: Bool) {
        guard let preview = store.switchPreview else { return }
        if let id, let key = profiles.first(where: { $0.id == id })?.key, key == preview.profile {
            store.confirmSwitchPreview(profile: key)
        } else if isFinal, dockedNumber != previewDockedNumber {
            store.endSwitchPreview(because: "another window came to the front")
        }
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
            tellStoreDockedProfile()
        }
    }

    /// Symbols from windows that aren't docked (read at launch, or as they open), for profiles whose
    /// windows say which profile they are without a doubt. Profiles sharing a name are told apart by
    /// elimination as symbols become known, so this goes round until nothing more is learned.
    private func learnSymbols(from toolbars: [ToolbarProfile]) {
        var updated = profiles
        // Each profile's symbol is set once per call, so two readings that disagree (one from before
        // the symbol was changed) can't take turns.
        var settled = Set<UUID>()
        var learned = true
        var passes = 0
        while learned, passes <= updated.count {
            learned = false
            passes += 1
            for toolbar in toolbars {
                guard case .profile(_, let symbol?) = toolbar,
                      let id = ProfileRules.resolve(toolbar, windowTitle: nil, profiles: updated, copyWindows: []).profileID,
                      !settled.contains(id),
                      let index = updated.firstIndex(where: { $0.id == id }), updated[index].symbol != symbol else { continue }
                updated[index].symbol = symbol
                settled.insert(id)
                learned = true
                log.notice("profile \(index) has the symbol \(symbol, privacy: .public)")
            }
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

    /// The extension copies sending heartbeats: the store leaves out a copy that has gone quiet (Side
    /// Tabs turned off in its profile) or been replaced by a newer copy of its profile (#31). That's
    /// what lets an "on" profile become "off".
    private var liveInstances: Set<String> {
        store.liveInstances
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
    /// without Accessibility access. Says whether a switch started (it brings Safari forward).
    @discardableResult
    func select(_ profile: SafariProfile) -> Bool {
        guard profile.id != highlightedID else { return false }
        return beginSwitch(to: profile)
    }

    /// Which profile a window belongs to, with what's known now, for work done off the main thread.
    func makeResolver() -> ProfileResolver {
        ProfileResolver(profiles: profiles, copyWindows: copyWindows)
    }

    /// A press on the sidebar this recent is the one that started a switch.
    private static let clickStartsSwitch: TimeInterval = 1

    /// Brings `profile`'s window forward in place of the docked one, or opens one. `frame`: where it goes,
    /// if not the docked window's spot. `clickAt`: the click that asked for it, outside the sidebar (the Dock
    /// icon); otherwise a press on the sidebar just now, or else the switch's own start, is what it's timed
    /// from. `then` runs on the main thread when it's done, with whether the profile's window came to the
    /// front. Says whether a switch started.
    @discardableResult
    func beginSwitch(to profile: SafariProfile, reason: MinimizeReason = .switched, frame override: CGRect? = nil,
                     clickAt click: Date? = nil, then: ((Bool) -> Void)? = nil) -> Bool {
        guard let app = application,
              let position = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        // Not an older press: a switch nobody clicked for in the sidebar (the Dock icon, say) would otherwise be
        // timed from whenever the sidebar was last pressed.
        let now = Date()
        let press = (store.lastPointerDown?()).flatMap { now.timeIntervalSince($0) < Self.clickStartsSwitch ? $0 : nil }
        let clickAt = click ?? press ?? now
        let since = click != nil ? "the click on the Dock icon" : press != nil ? "the click" : "the switch began"
        let pending = PendingSwitch(id: profile.id, at: Date())
        pendingSwitch = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + PendingSwitch.lifetime) { [weak self] in
            guard let self, self.pendingSwitch == pending else { return }
            self.pendingSwitch = nil
            self.log.notice("the switch to profile \(position) didn't show in time; the highlight follows Safari again")
        }

        let docked = tracker.window
        let frame = override ?? docked.flatMap { tracker.isFullScreen($0) ? nil : tracker.frame(of: $0) }
        var request = ProfileSwitcher.Request(
            application: app.element,
            processIdentifier: app.pid,
            profile: profile,
            position: position,
            frame: frame,
            resolve: makeResolver()
        )
        let sweepStart = minimizing.switchStarting(to: profile.id, reason: reason)
        request.sweep = sweepStart.sweep
        request.sweepGeneration = sweepStart.generation
        // What the sidebar shows while the window comes in (#44): only for the buttons, the dropdown and a closed
        // tab reopening. The Dock icon's window replaces one the sidebar may already be showing.
        latestPreview += 1
        let previewID = latestPreview
        if reason == .switched {
            previewAtClick(id: previewID, profile: profile, clickAt: clickAt)
            request.onTarget = { [weak self] choice in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.switchPicked(choice, preview: previewID, profile: profile, clickAt: clickAt) }
                }
            }
        }
        log.notice("switching to profile \(position)\(reason == .switched ? "" : " (\(reason.rawValue))", privacy: .public)")
        let profileID = profile.id
        switcher.switchTo(request, clickAt: clickAt) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.switchFinished(outcome, pending: pending, position: position, since: since)
                    let succeeded: Bool
                    switch outcome {
                    case .raised, .opened: succeeded = true
                    case .menuOutOfDate, .superseded, .failed: succeeded = false
                    }
                    if case .superseded = outcome {
                        // A newer click has its own preview.
                    } else if !succeeded, self.store.switchPreview?.id == previewID {
                        self.store.endSwitchPreview(because: "the switch didn't work")
                    }
                    self.minimizing.switchFinished(token: sweepStart.token, profile: profileID, succeeded: succeeded)
                    then?(succeeded)
                }
            }
        }
        return true
    }

    /// `since`: what the times are from, for the log.
    private func switchFinished(_ outcome: ProfileSwitcher.Outcome, pending: PendingSwitch, position: Int, since: String) {
        switch outcome {
        case .raised(let milliseconds, let minimized):
            log.notice("switched to profile \(position): its window was Safari's main window \(milliseconds) ms after \(since, privacy: .public)\(minimized ? " (it was minimized)" : "", privacy: .public)")
            if minimized {
                // How long a minimized window takes to land, for the next fade (#44).
                arrivalEstimate = SwitchPreviewRules.arrivalEstimate(after: arrivalEstimate, measured: Double(milliseconds) / 1000)
            }
        case .opened(let milliseconds):
            log.notice("switched to profile \(position): it had no window; a new one appeared \(milliseconds) ms after \(since, privacy: .public)")
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

    // MARK: - The sidebar while the window comes in (#44)

    /// At the click: with "Minimize other profiles' windows" on, the target is nearly always in the Dock, so the
    /// sidebar fades over to the profile now, with its guess from the store alone (the copy's last focused
    /// window). Without the setting, it waits for the switch to say whether the target is minimized.
    private func previewAtClick(id: Int, profile: SafariProfile, clickAt: Date) {
        guard let key = profile.key,
              SwitchPreviewRules.fades(targetIsMinimized: nil, minimizesOtherProfiles: settings.minimizesOtherProfiles) else { return }
        let guess = SwitchPreviewRules.guess(SwitchTarget(profile: key), copies: Array(store.liveSnapshots.values))
        beginPreview(id: id, profile: key, guess: guess, arrivesAt: clickAt.addingTimeInterval(arrivalEstimate))
    }

    /// The switch has picked its window, through Accessibility, before bringing it forward: a better guess from
    /// its title, or, when the target is in the Dock and nothing is shown yet, the fade starts now. A target that's
    /// already open stays as it was: Safari reports it in about 0.1 s.
    private func switchPicked(_ choice: ProfileSwitcher.TargetChoice, preview id: Int, profile: SafariProfile, clickAt: Date) {
        guard id == latestPreview, let key = profiles.first(where: { $0.id == profile.id })?.key ?? profile.key else { return }
        let target = SwitchTarget(profile: key, title: choice.title, isNewWindow: choice.window == nil, profileWindowCount: choice.profileWindowCount)
        let guess = SwitchPreviewRules.guess(target, copies: Array(store.liveSnapshots.values))
        if store.switchPreview?.id == id {
            store.refineSwitchPreview(id: id, guess: guess)
        } else if choice.window != nil,
                  SwitchPreviewRules.fades(targetIsMinimized: choice.isMinimized, minimizesOtherProfiles: settings.minimizesOtherProfiles) {
            beginPreview(id: id, profile: key, guess: guess, arrivesAt: clickAt.addingTimeInterval(arrivalEstimate))
        }
        if guess == .unseen, let window = choice.window, store.switchPreview?.id == id {
            unseenTabs.preview(window)
        }
    }

    private func beginPreview(id: Int, profile key: ProfileKey, guess: SwitchGuess, arrivesAt: Date) {
        previewDockedNumber = dockedNumber
        store.beginSwitchPreview(id: id, profile: key, guess: guess, arrivesAt: arrivesAt)
        refreshArrivalEstimate()
    }

    /// A minimized window is coming back some other way (a Dock tile, the Window menu, App Exposé): if it's
    /// another profile's and isn't in front yet, the sidebar fades over to it now, rather than once Safari
    /// reports it. Not for the windows Side Tabs brings back itself (a switch's, a sweep's), and not while the
    /// Dock icon rule may turn the window away (#42).
    private func windowComingBack(_ window: AXUIElement) {
        guard tracker.isTrusted, !minimizing.watchesDockIcon else { return }
        if let docked = dockedWindow, CFEqual(docked, window) { return }
        let reader = reader
        let minimizer = minimizer
        reader.queue.async { [weak self] in
            let (number, toolbar) = reader.toolbarProfile(of: window)
            guard let number, !minimizer.restoredJustNow(number) else { return }
            reader.query.clearTimedOut()
            let title = reader.query.string(window, kAXTitleAttribute)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.otherWindowComingBack(window, number: number, toolbar: toolbar, title: title)
                }
            }
        }
    }

    private func otherWindowComingBack(_ window: AXUIElement, number: Int, toolbar: ToolbarProfile, title: String?) {
        // Already in front: the sidebar follows it as it is.
        guard number != dockedNumber, !(dockedWindow.map { CFEqual($0, window) } ?? false) else { return }
        let resolution = ProfileRules.resolve(toolbar, windowTitle: title, profiles: profiles, copyWindows: copyWindows)
        guard let id = resolution.profileID, let position = profiles.firstIndex(where: { $0.id == id }),
              let key = profiles[position].key, key != store.shownProfile else { return }
        latestPreview += 1
        let guess = SwitchPreviewRules.guess(SwitchTarget(profile: key, title: title), copies: Array(store.liveSnapshots.values))
        log.notice("a minimized window of profile \(position) is coming back: the sidebar fades over to it")
        // Its animation has begun already.
        beginPreview(id: latestPreview, profile: key, guess: guess, arrivesAt: Date().addingTimeInterval(SwitchPreviewRules.alreadyOnItsWay))
    }

    /// The Dock's minimize effect sets how long a window takes to come back from the Dock, until switches have
    /// measured it. A change of effect starts the estimate over.
    private func refreshArrivalEstimate() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let effect = Self.minimizeEffect()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.minimizeEffect != .some(effect) else { return }
                    self.minimizeEffect = .some(effect)
                    self.arrivalEstimate = SwitchPreviewRules.arrivalEstimate(minimizeEffect: effect)
                }
            }
        }
    }

    /// The Dock's `mineffect` ("genie", "scale"). Side Tabs only reads the Dock's settings.
    nonisolated private static func minimizeEffect() -> String? {
        let dock = "com.apple.dock" as CFString
        _ = CFPreferencesAppSynchronize(dock)
        return CFPreferencesCopyAppValue("mineffect" as CFString, dock) as? String
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
            let createdAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.windowAppeared(element, createdAt: createdAt)
            }
        case kAXFocusedWindowChangedNotification:
            checkSettingsClosed()
            // A window closed, or another came forward: the windows like the docked one may have changed.
            countLikeWindows()
        case kAXWindowDeminiaturizedNotification:
            windowComingBack(element)
        default:
            break
        }
        minimizing.notified(name)
    }

    private func windowAppeared(_ window: AXUIElement, createdAt: Date) {
        guard tracker.isTrusted else { return }
        let reader = reader
        reader.queue.async { [weak self] in
            let (number, toolbar) = reader.toolbarProfile(of: window)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.countLikeWindows()
                    let resolution = ProfileRules.resolve(toolbar, windowTitle: nil, profiles: self.profiles, copyWindows: [])
                    self.minimizing.windowAppeared(number: number, profile: resolution, createdAt: createdAt)
                    guard case .profile(let name, _) = toolbar, !name.isEmpty else { return }
                    if self.profiles.contains(where: { ProfileIdentifiers.sameName($0.name, name) }) {
                        self.learnSymbols(from: [toolbar])
                    } else {
                        self.lookUp(toolbar, because: "a window of a profile the list doesn't have")
                    }
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
                        // Names and symbols change in Settings, so every window's profile is read again.
                        reader.queue.async { reader.forgetToolbars() }
                        self.readMenu(because: "Settings closed")
                        if let window = self.dockedWindow {
                            self.readDockedToolbar(window)
                        }
                        // Safari may rebuild its menu a moment later, and a profile just added has no
                        // window yet to show the first read was short: one more look.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            self?.readMenu(because: "Settings closed, a second look")
                        }
                    }
                }
            }
        }
    }
}
