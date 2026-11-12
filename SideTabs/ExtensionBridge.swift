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

    /// Tells this launch's command ids apart from an earlier launch's, which a copy of the extension may
    /// still remember.
    private let launchTag = String(UUID().uuidString.prefix(8))
    private var commandCount = 0

    /// A command couldn't be delivered because Safari runs no extension of this app's (`SFErrorNoExtensionFound`):
    /// another copy's, most likely (#67). Runs on the main thread.
    var onNoExtensionFound: (() -> Void)?

    /// Sends a command to background.js. `command["instance"]` limits it to one profile. `failed` runs on the
    /// main thread if Safari couldn't take it (#67), so the sidebar can put back what it changed for it.
    ///
    /// Every command gets an id, and background.js skips one it has already run: after the extension
    /// reloads, Safari has delivered commands to a copy twice (#37).
    ///
    /// A command that fails isn't sent again some other way, such as in the reply to a heartbeat, though
    /// background.js would still run `commands` from a reply: heartbeats come 5 s apart, replies are lost for
    /// minutes after the extension reloads (#31, #37), and a command run late is what #20 was about. The
    /// window goes back to what its copy last reported instead (#67).
    func send(_ command: [String: Any], failed: (() -> Void)? = nil) {
        commandCount += 1
        var command = command
        command["id"] = "\(launchTag)-\(commandCount)"
        let action = command["action"] as? String ?? "?"
        SFSafariApplication.dispatchMessage(
            withName: "command",
            toExtensionWithIdentifier: SideTabsBridge.extensionBundleIdentifier,
            userInfo: command
        ) { [log, weak self] error in
            guard let error else { return }
            let noExtension = Self.isNoExtensionFound(error)
            log.error("dispatchMessage failed (“\(action, privacy: .public)”): \(error.localizedDescription, privacy: .public)\(noExtension ? "; Safari runs no extension of this app's" : "", privacy: .public)")
            DispatchQueue.main.async {
                failed?()
                if noExtension {
                    self?.onNoExtensionFound?()
                }
            }
        }
    }

    /// `SFErrorDomain` error 1: Safari has no extension with this identifier inside the app that sent the command.
    nonisolated static func isNoExtensionFound(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SFErrorDomain && error.code == SFErrorCode.noExtensionFound.rawValue
    }
}
