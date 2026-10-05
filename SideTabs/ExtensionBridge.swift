import Foundation
import SafariServices
import os.log

/// The app's end of the connection to the Safari extension.
///
/// Incoming: SafariWebExtensionHandler forwards each `sendNativeMessage` call over a
/// CFMessagePort and waits for the reply.
/// Outgoing: `SFSafariApplication.dispatchMessage` delivers commands to the port that
/// background.js opened with `connectNative`.
final class ExtensionBridge {
    /// Handles one JSON message from the extension and returns the JSON reply.
    var onMessage: ((_ type: String, _ payload: Data, _ object: [String: Any]) -> [String: Any])?

    private(set) var isListening = false
    private var port: CFMessagePort?
    private var seenTypes: Set<String> = []
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "bridge")

    func start() {
        guard port == nil else { return }

        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        var shouldFreeInfo: DarwinBoolean = false
        let callback: CFMessagePortCallBack = { _, _, data, info in
            guard let info, let data else { return nil }
            let bridge = Unmanaged<ExtensionBridge>.fromOpaque(info).takeUnretainedValue()
            let reply = MainActor.assumeIsolated { bridge.handle(data as Data) }
            return Unmanaged.passRetained(reply as CFData)
        }

        guard let port = CFMessagePortCreateLocal(nil, SideTabsBridge.portName as CFString, callback, &context, &shouldFreeInfo) else {
            log.error("Could not open message port \(SideTabsBridge.portName, privacy: .public); is Side Tabs already running?")
            return
        }
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.port = port
        isListening = true
        log.notice("Listening on \(SideTabsBridge.portName, privacy: .public)")
    }

    private func handle(_ data: Data) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else {
            return Data("{}".utf8)
        }
        if seenTypes.insert(type).inserted {
            log.notice("first “\(type, privacy: .public)” message from the extension")
        }
        var reply = onMessage?(type, data, object) ?? [:]
        reply["appRunning"] = true
        return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
    }

    /// Sends a command to background.js. `command["instance"]` limits it to one profile.
    func send(_ command: [String: Any]) {
        SFSafariApplication.dispatchMessage(
            withName: "command",
            toExtensionWithIdentifier: SideTabsBridge.extensionBundleIdentifier,
            userInfo: command
        ) { [log] error in
            if let error {
                log.error("dispatchMessage failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
