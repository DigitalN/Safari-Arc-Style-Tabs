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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let store = TabStore()
    let favicons = FaviconStore()

    private let bridge = ExtensionBridge()
    private let tracker = SafariTracker()
    private let accessibilityWatcher = AccessibilityWatcher()
    private var dock: DockController?
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            NSApp.terminate(nil)
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
            guard let self else { return }
            self.bridge.send(command)
            if let action = command["action"] as? String, action == "activate" || action == "create" {
                self.dock?.bringSafariForward()
            }
        }
        store.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        store.onRenameStateChanged = { [weak self] editing in self?.dock?.setEditing(editing) }

        dock.start()
        store.requestSnapshot()

        accessibilityWatcher.onGranted = { AccessibilityWatcher.relaunch() }
        accessibilityWatcher.start()

        if !settings.hasCompletedSetup || !Permissions.accessibilityGranted {
            showWelcome()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dock?.restoreSafariFrame()
        store.save()
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
            let view = WelcomeView(onDone: { [weak self] in
                self?.settings.hasCompletedSetup = true
                self?.welcomeWindow?.close()
            })
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
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
