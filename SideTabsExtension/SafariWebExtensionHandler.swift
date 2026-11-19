import AppKit
import SafariServices
import os.log

/// Relays `browser.runtime.sendNativeMessage` calls from background.js to the Side Tabs
/// app and returns the app's reply to JavaScript.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let log = Logger(subsystem: SideTabsBridge.extensionBundleIdentifier, category: "bridge")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let profile = item?.userInfo?[SFExtensionProfileKey] as? UUID

        var envelope = message
        if let profile {
            envelope["profile"] = profile.uuidString
        }
        // Where this copy of the extension is, so the app can tell when Safari runs another copy's: commands
        // from the app only reach the extension inside it (#67).
        envelope["extensionPath"] = Bundle.main.bundlePath

        var reply: [String: Any] = ["appRunning": false]
        if let data = try? JSONSerialization.data(withJSONObject: envelope) {
            if let replyData = Self.sendToApp(data) {
                reply = (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any] ?? ["appRunning": true]
            } else if message["launchApp"] as? Bool == true, !Self.appIsRunning {
                launchContainingApp()
            }
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private static func sendToApp(_ data: Data) -> Data? {
        AppPort.send(data)
    }

    /// The app doesn't answer while it's starting up or quitting. Opening it then would only
    /// reach the running copy, which takes that as the user reopening it and shows Settings.
    private static var appIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: SideTabsBridge.appBundleIdentifier)
            .contains { !$0.isTerminated }
    }

    /// The extension lives at `Side Tabs.app/Contents/PlugIns/Side Tabs Extension.appex`.
    private func launchContainingApp() {
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [log] _, error in
            if let error {
                log.error("Could not launch Side Tabs: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The app's message port, looked up once and kept, rather than looked up (a bootstrap name lookup) and torn
/// down again for every message (#84). It's looked up again when the kept one is no longer valid, or a send
/// through it fails because the app is gone: the app quit or was relaunched, and a relaunched app's port is
/// a new port under the same name.
///
/// Sends go one at a time. `beginRequest` can run on several threads at once, and CFMessagePort isn't
/// documented as safe to send through from two threads at once: every send through a port shares its table
/// of conversations and its one reply port, which each send waits on from its own thread's run loop. The app
/// answers its messages one at a time on its main thread anyway.
private enum AppPort {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var port: CFMessagePort?
    private static let log = Logger(subsystem: SideTabsBridge.extensionBundleIdentifier, category: "bridge")

    /// Sends `data` to the app and returns its reply, or nil if the app isn't there or didn't answer.
    static func send(_ data: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        for attempt in 0..<2 {
            guard let remote = currentPort() else { return nil }
            var replyData: Unmanaged<CFData>?
            let status = CFMessagePortSendRequest(
                remote,
                SideTabsBridge.messageID,
                data as CFData,
                1.0,
                2.0,
                CFRunLoopMode.defaultMode.rawValue,
                &replyData
            )
            if status == kCFMessagePortSuccess {
                return replyData?.takeRetainedValue() as Data?
            }
            switch status {
            case kCFMessagePortIsInvalid, kCFMessagePortTransportError:
                // Not sent: the port died (the app quit or was relaunched) before CF noticed. Look it up
                // again and send once more, which reaches a relaunched app.
                discard(remote)
                if attempt == 0 {
                    log.notice("The app's message port was gone (status \(status, privacy: .public)): looking it up again")
                    continue
                }
            case kCFMessagePortBecameInvalidError:
                // Sent, but the app went away before answering: it may have acted on it, so it isn't sent
                // again. The next message looks the port up again.
                log.notice("The app went away before answering: its message port will be looked up again")
                discard(remote)
            default:
                // A time-out: the app is there but busy. The port is still good.
                break
            }
            return nil
        }
        return nil
    }

    /// The kept port if it's still valid, else a new one, or nil if the app isn't running.
    private static func currentPort() -> CFMessagePort? {
        if let port, CFMessagePortIsValid(port) {
            return port
        }
        if let port {
            log.notice("The app's message port is no longer valid: looking it up again")
            discard(port)
        }
        port = CFMessagePortCreateRemote(nil, SideTabsBridge.portName as CFString)
        return port
    }

    /// Invalidating it also takes it out of CF's table of remote ports by name, so the next
    /// CFMessagePortCreateRemote looks the name up again instead of handing back this one.
    private static func discard(_ remote: CFMessagePort) {
        CFMessagePortInvalidate(remote)
        if port === remote {
            port = nil
        }
    }
}
