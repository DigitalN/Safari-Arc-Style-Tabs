import AppKit

// Use an isolated native message port and simulated browser presence. This exercises
// the real app bridge without opening Safari or touching saved tabs and preferences.
enum SafariTracker {
    static var isSafariRunning = false
}
enum SideTabsBridge {
    static let appBundleIdentifier = "com.digitaln.sidetabs.lifecycle-tests"
    static let portName = appBundleIdentifier + "." + UUID().uuidString
}

nonisolated final class BridgeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any]?
    var value: [String: Any]? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

@main struct BridgeLifecycleTests {
    static func poll(acks: [String] = []) -> [String: Any] {
        let reply = BridgeReply()
        let name = SideTabsBridge.portName
        let data = try! JSONSerialization.data(withJSONObject: [
            "type": "commandPoll", "instance": "test-session",
            "commandTransport": "queue-v1", "commandAcks": acks,
        ])
        DispatchQueue.global().async {
            guard let port = CFMessagePortCreateRemote(nil, name as CFString) else {
                reply.value = ["error": "missing message port"]
                return
            }
            defer { CFMessagePortInvalidate(port) }
            var response: Unmanaged<CFData>?
            let status = CFMessagePortSendRequest(port, 1, data as CFData, 1, 2,
                                                 CFRunLoopMode.defaultMode.rawValue, &response)
            guard status == kCFMessagePortSuccess, let response = response?.takeRetainedValue(),
                  let object = try? JSONSerialization.jsonObject(with: response as Data) as? [String: Any] else {
                reply.value = ["error": "native message failed"]
                return
            }
            reply.value = object
        }
        let deadline = Date().addingTimeInterval(4)
        while reply.value == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let result = reply.value, result["error"] == nil else {
            fatalError("Native polling failed: \(String(describing: reply.value))")
        }
        return result
    }

    static func main() {
        let bridge = ExtensionBridge()
        bridge.start()
        precondition(bridge.isListening, "isolated bridge must start")
        bridge.send(["action": "snapshot"])
        precondition(poll()["commands"] == nil, "closed browser must not queue cleanup snapshots")

        SafariTracker.isSafariRunning = true
        bridge.send(["action": "activate", "instance": "test-session", "tabId": 7])
        let reply = poll()
        let commands = reply["commands"] as! [[String: Any]]
        precondition(commands.count == 1 && commands[0]["tabId"] as? Int == 7,
                     "running browser receives commands through polling alone")
        let id = commands[0]["commandID"] as! String
        precondition(poll(acks: [id])["commands"] == nil, "poll acknowledges command delivery")

        SafariTracker.isSafariRunning = false
        bridge.send(["action": "create", "url": "https://example.com"])
        SafariTracker.isSafariRunning = true
        precondition(poll()["commands"] == nil, "commands for a closed session never replay after reopening")
        print("Passed 4 native bridge lifecycle checks.")
    }
}
