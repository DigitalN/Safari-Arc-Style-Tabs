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
/// Messages don't wait for each other. `beginRequest` can run on several threads at once, and each message is
/// sent through the kept port as soon as it comes, even while another is still waiting for its reply: CF keeps
/// every send's conversation apart, so each gets its own reply (Tests/AppPortChecks sends from several
/// threads at once). A separate port per message can't be had anyway: CFMessagePortCreateRemote hands back
/// the same object for a name while one is alive. So while the app is stalled, each message times out on its
/// own clock, within background.js's reply limit, instead of queueing behind the others past it and being
/// counted as lost. The lock only covers looking the port up and replacing it, never a send.
enum AppPort {
    /// The longest one message may take, both tries together. background.js counts a message with no reply
    /// within 4 s as lost (REPLY_TIME_LIMIT_MS); this leaves room for Safari passing it and its reply along.
    static let timeLimit: TimeInterval = 3.5
    /// How long one try waits for room in the app's queue, then for the app's reply.
    static let sendTimeout: TimeInterval = 1
    static let replyTimeout: TimeInterval = 2
    /// The name the app registers its port under. Tests/AppPortChecks points it at a port of its own.
    nonisolated(unsafe) static var portName = SideTabsBridge.portName

    private static let lock = NSLock()
    private nonisolated(unsafe) static var port: CFMessagePort?
    private static let log = Logger(subsystem: SideTabsBridge.extensionBundleIdentifier, category: "bridge")

    /// The port kept for the next message, if any.
    static var keptPort: CFMessagePort? {
        lock.withLock { port }
    }

    /// Sends `data` to the app and returns its reply, or nil if the app isn't there or didn't answer in time.
    static func send(_ data: Data) -> Data? {
        let deadline = Date().addingTimeInterval(timeLimit)
        for attempt in 0..<2 {
            // A second try gets only what's left of the time limit.
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.25, let remote = currentPort() else { return nil }
            let sendTime = min(sendTimeout, remaining / 3)
            let replyTime = min(replyTimeout, remaining - sendTime)
            var replyData: Unmanaged<CFData>?
            let status = CFMessagePortSendRequest(
                remote,
                SideTabsBridge.messageID,
                data as CFData,
                sendTime,
                replyTime,
                CFRunLoopMode.defaultMode.rawValue,
                &replyData
            )
            if status == kCFMessagePortSuccess {
                return replyData?.takeRetainedValue() as Data?
            }
            switch status {
            case kCFMessagePortIsInvalid, kCFMessagePortTransportError:
                // Not sent: the port died (the app quit or was relaunched) before CF noticed. Both come back
                // at once, not after a time-out. Look it up again and send once more, which reaches a
                // relaunched app.
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
                // A time-out: the app is there but stalled. The port is still good, and trying again would
                // only take longer than background.js waits.
                break
            }
            return nil
        }
        return nil
    }

    /// The kept port if it's still valid, else a new one, or nil if the app isn't running.
    private static func currentPort() -> CFMessagePort? {
        lock.withLock {
            if let port, CFMessagePortIsValid(port) {
                return port
            }
            if let port {
                log.notice("The app's message port is no longer valid: looking it up again")
                // Invalidating it also takes it out of CF's table of remote ports by name, so
                // CFMessagePortCreateRemote looks the name up again instead of handing back this one.
                CFMessagePortInvalidate(port)
            }
            port = CFMessagePortCreateRemote(nil, portName as CFString)
            return port
        }
    }

    /// Drops `remote` if it's still the kept port. Another message may have replaced it already, and then
    /// invalidated it while doing so.
    private static func discard(_ remote: CFMessagePort) {
        lock.withLock {
            guard port === remote else { return }
            CFMessagePortInvalidate(remote)
            port = nil
        }
    }
}
