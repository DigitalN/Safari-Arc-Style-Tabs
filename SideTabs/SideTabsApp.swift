import AppKit
import ApplicationServices
import SwiftUI

@main
struct SideTabsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // AccessibilityWatcher runs us with this flag to get an up-to-date answer.
        if CommandLine.arguments.contains(AccessibilityWatcher.checkArgument) {
            exit(AccessibilityAccess.isGranted ? 0 : 1)
        }
    }

    var body: some Scene {
        MenuBarExtra("Side Tabs", systemImage: "sidebar.left") {
            MenuContent(app: appDelegate)
                .environment(appDelegate.settings)
                .environment(appDelegate.store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = AppSettings()
    let store = TabStore()
    let favicons = FaviconStore()
    private(set) lazy var updater = Updater(settings: settings)

    private let bridge = ExtensionBridge()
    private let tracker = SafariTracker()
    private let accessibilityWatcher = AccessibilityWatcher()
    private var dock: DockController?
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?
    /// Set while Side Tabs activates itself to show one of its own windows.
    private var presentingOwnWindow = false
    /// Set when quitting to relaunch into an update.
    private var relaunchingForUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        replaceOlderCopies()
        if !AppLocation.isInApplicationsFolder, AppLocation.offerToMove() {
            return
        }

        let panel = SidebarPanel(rootView: SidebarView()
            .environment(store)
            .environment(settings)
            .environment(favicons))
        let dock = DockController(panel: panel, tracker: tracker, settings: settings, store: store)
        self.dock = dock

        bridge.onMessage = { [store] type, payload, object in
            store.handleMessage(type: type, payload: payload, object: object)
        }
        bridge.start()

        store.sendCommand = { [weak self] command in
            self?.bridge.send(command)
        }
        store.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        store.onRenameStateChanged = { [weak self] editing in self?.dock?.setEditing(editing) }
        store.onOpenAddressBar = { [weak self] in self?.dock?.openSafariAddressBar() }

        dock.start()
        store.requestSnapshot()

        accessibilityWatcher.onGranted = { AccessibilityWatcher.relaunch() }
        accessibilityWatcher.start()

        if AppLocation.isInApplicationsFolder {
            settings.turnOnLaunchAtLoginByDefault()
        }
        showSetupIfNeeded()

        updater.isBusy = { [weak self] in
            guard let self else { return true }
            return self.store.renaming != nil || [self.welcomeWindow, self.settingsWindow].contains { $0?.isVisible == true }
        }
        updater.willRelaunch = { [weak self] in self?.relaunchingForUpdate = true }
        updater.start()
    }

    /// Setup shows until Accessibility and the Safari extension are both on, and again right
    /// after the restart that follows granting Accessibility. After that, Side Tabs starts
    /// quietly in the menu bar. (The sidebar itself explains website access if it's missing.)
    private func showSetupIfNeeded() {
        if CommandLine.arguments.contains(AccessibilityWatcher.resumeSetupArgument) || !Permissions.accessibilityGranted {
            showWelcome()
            return
        }
        guard !settings.hasCompletedSetup else { return }
        Task { @MainActor in
            if await Permissions.extensionEnabled() {
                settings.hasCompletedSetup = true
            } else {
                showWelcome()
            }
        }
    }

    /// The most recently opened copy wins, so opening a freshly downloaded update takes
    /// over from the old one still running (and from a copy opened off the disk image).
    /// The old copy has to be gone first: it holds the extension's message port.
    private func replaceOlderCopies() {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // After an update, the new copy docks right where this one is, so leave Safari's
        // window alone rather than widening it only to narrow it again a second later.
        if !relaunchingForUpdate {
            dock?.restoreSafariFrame()
        }
        store.save()
    }

    /// Side Tabs only becomes the active app to show its own windows, or when the sidebar
    /// itself is picked, e.g. in Mission Control. In that case the user wants Safari.
    func applicationDidBecomeActive(_ notification: Notification) {
        let ownWindowShowing = [welcomeWindow, settingsWindow].contains { $0?.isVisible == true }
        guard !presentingOwnWindow, !ownWindowShowing, NSApp.modalWindow == nil else { return }
        dock?.bringSafariForward()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// The toolbar button, its keyboard shortcut, and the menu bar item. In full screen the
    /// sidebar is a hover overlay, so this slides it out or away instead of turning it off.
    func toggleSidebar() {
        if settings.sidebarVisible, let dock, dock.isShowingFullScreenOverlay {
            dock.toggleOverlay()
        } else {
            settings.sidebarVisible.toggle()
        }
    }

    func showWelcome() {
        if welcomeWindow == nil {
            let view = WelcomeView(
                onFinish: { [weak self] in
                    self?.welcomeWindow?.close()
                    self?.dock?.bringSafariForward()
                },
                onLater: { [weak self] in
                    self?.welcomeWindow?.close()
                },
                onStepCompleted: { [weak self] in
                    // The step was finished in System Settings or Safari; show what's next.
                    guard let window = self?.welcomeWindow, window.isVisible else { return }
                    self?.present(window)
                }
            )
            .environment(store)
            .environment(settings)
            welcomeWindow = makeWindow(title: "Set Up Side Tabs", content: view)
        }
        present(welcomeWindow)
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Side Tabs Settings", content: SettingsView().environment(settings))
        }
        present(settingsWindow)
    }

    private func makeWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Side Tabs has nothing to show once its last window closes, so step aside and let
    /// macOS give focus back to the previous app instead of leaving keystrokes going nowhere.
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let stillOpen = [self.welcomeWindow, self.settingsWindow].contains { $0 !== closing && $0?.isVisible == true }
            if !stillOpen && NSApp.isActive {
                NSApp.deactivate()
            }
        }
    }

    /// macOS may refuse to make Side Tabs the active app, e.g. right after it restarts itself
    /// while System Settings is in front. Then `makeKeyAndOrderFront` leaves the window
    /// behind the active app, so also order it front regardless; clicking it activates us.
    private func present(_ window: NSWindow?) {
        presentingOwnWindow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.presentingOwnWindow = false
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
