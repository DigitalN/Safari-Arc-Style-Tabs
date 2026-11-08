import AppKit

/// Runs tab cleanup (TabCleanup.swift) every few minutes and whenever Safari comes forward, and starts
/// or stops its clocks as the setting is turned on or off.
final class TabCleanupScheduler {
    /// How often cleanup runs. The shortest choice in Settings is 12 hours, so a few minutes late
    /// makes no difference.
    static let period: TimeInterval = 5 * 60
    /// How long after Safari comes forward cleanup runs. Clicking a tab in Safari's own tab bar can be
    /// what brings Safari forward, and the extension's report of that switch comes after; until it
    /// does, the tab clicked on would look idle and could be closed under the pointer.
    static let activationDelay: TimeInterval = 5

    private let store: TabStore
    private let settings: AppSettings
    private var timer: Timer?
    private var activationToken: NSObjectProtocol?
    private var pendingRun: DispatchWorkItem?

    init(store: TabStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        guard timer == nil else { return }
        settingsChanged()
        observeSettings()

        let timer = Timer(timeInterval: Self.period, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SafariTracker.safariBundleID else { return }
            MainActor.assumeIsolated { self?.runSoon() }
        }
    }

    private func runSoon() {
        pendingRun?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.run() }
        pendingRun = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationDelay, execute: work)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.closesUnviewedTabs
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    private func settingsChanged() {
        store.cleanup.setOn(settings.closesUnviewedTabs, tabs: store.snapshots)
    }

    private func run() {
        guard settings.closesUnviewedTabs else { return }
        store.runCleanup(after: settings.unviewedTabInterval.seconds)
    }
}
