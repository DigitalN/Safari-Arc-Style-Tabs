import AppKit
import CoreGraphics

/// Watches for the times Safari holds its extension copies back though nothing is wrong with them (#45): the
/// Mac asleep, its displays asleep, the screen locked or the screen saver on, the session switched away
/// (fast user switching), Safari hidden. The store doesn't count a copy's silence then (CopySilence), and
/// starts every copy over when the last of them ends.
///
/// Where macOS can say how things are now, `holds` asks it rather than trusting a notification, so a
/// notification that never comes can't hold the copies back for good. Sleep and the screen saver can only
/// be told from their notifications. Lives as long as the app.
final class HoldWatcher {
    /// Called whenever a hold may have begun or ended.
    var onChange: (() -> Void)?

    private var asleep = false
    private var screenSaverRunning = false
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { watcher in
            watcher.asleep = false
            // Nothing runs a screen saver right after waking, whatever was said before the Mac slept.
            watcher.screenSaverRunning = false
        }
        for name in [
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            observe(workspace, name) { _ in }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { _ in }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { _ in }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.screenSaverRunning = true }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.screenSaverRunning = false }
    }

    /// What's holding Safari's copies back now.
    var holds: Set<CopySilence.Hold> {
        var holds: Set<CopySilence.Hold> = []
        if asleep {
            holds.insert(.asleep)
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            holds.insert(.displaysAsleep)
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true {
            holds.insert(.screenLocked)
        }
        if screenSaverRunning {
            holds.insert(.screenSaver)
        }
        if session?[kCGSessionOnConsoleKey] as? Bool == false {
            holds.insert(.sessionInactive)
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: SafariTracker.safariBundleID).contains(where: \.isHidden) {
            holds.insert(.safariHidden)
        }
        return holds
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping (HoldWatcher) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.onChange?()
            }
        }
        tokens.append((center, token))
    }
}
