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

        var reply: [String: Any] = ["appRunning": false]
        if let data = try? JSONSerialization.data(withJSONObject: envelope) {
            if let replyData = Self.sendToApp(data) {
                reply = (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any] ?? ["appRunning": true]
            } else if message["launchApp"] as? Bool == true {
                launchContainingApp()
            }
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private static func sendToApp(_ data: Data) -> Data? {
        guard let remote = CFMessagePortCreateRemote(nil, SideTabsBridge.portName as CFString) else {
            return nil
        }
        defer { CFMessagePortInvalidate(remote) }

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
        guard status == kCFMessagePortSuccess, let reply = replyData?.takeRetainedValue() else {
            return nil
        }
        return reply as Data
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
