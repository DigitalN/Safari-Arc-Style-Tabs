import Foundation

@main struct CommandQueueTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }
    static func main() {
        let queue = ExtensionCommandQueue()
        let now = Date(timeIntervalSince1970: 100)
        let client: [String: Any] = ["instance": "one", "commandTransport": ExtensionCommandQueue.transport]
        queue.enqueue(["action": "create", "instance": "one", "url": "https://example.com"], now: now)
        expect(queue.reply(to: ["instance": "one"], now: now).isEmpty, "legacy clients never receive retryable commands")
        expect(queue.reply(to: ["instance": "two", "commandTransport": ExtensionCommandQueue.transport], now: now).isEmpty,
               "another profile/session cannot receive targeted commands")
        let first = queue.reply(to: client, now: now)
        expect(first.count == 1 && first[0]["url"] as? String == "https://example.com", "working incoming channel carries click command")
        let id = first[0]["commandID"] as! String
        expect(queue.reply(to: client, now: now)[0]["commandID"] as? String == id, "lost reply retries with same ID")
        var wrongAck: [String: Any] = ["instance": "two", "commandTransport": ExtensionCommandQueue.transport, "commandAcks": [id]]
        _ = queue.reply(to: wrongAck, now: now)
        expect(queue.reply(to: client, now: now).count == 1, "wrong profile cannot acknowledge someone else's command")
        wrongAck["instance"] = "one"
        expect(queue.reply(to: wrongAck, now: now).isEmpty && queue.reply(to: client, now: now).isEmpty, "acknowledged target command is removed")

        queue.enqueue(["action": "snapshot"], now: now)
        let broadcast = queue.reply(to: client, now: now)[0]["commandID"] as! String
        var ack = client; ack["commandAcks"] = [broadcast]
        expect(queue.reply(to: ack, now: now).isEmpty, "broadcast acknowledged once per profile")
        var other = client; other["instance"] = "two"
        expect(queue.reply(to: other, now: now).count == 1, "snapshot broadcast still reaches other profiles")
        expect(queue.reply(to: other, now: now.addingTimeInterval(16)).isEmpty, "stale commands expire instead of replaying old clicks")
        queue.enqueue(["action": "activate", "instance": "one", "tabId": 3], now: now)
        queue.enqueue(["action": "create", "instance": "one", "requestId": "pin-open"], now: now)
        expect(queue.reply(to: client, now: now).map { $0["action"] as! String } == ["activate", "create"], "command order and original fields retained")
        expect(queue.reply(to: client, now: now)[1]["requestId"] as? String == "pin-open", "tab membership request token survives transport")
        let fresh = ExtensionCommandQueue()
        expect(fresh.reply(to: client, now: now).isEmpty, "app restart does not replay transient clicks")
        for _ in 0..<300 { fresh.enqueue(["action": "create", "instance": "one"], now: now) }
        expect(fresh.reply(to: client, now: now).count == 256, "disconnected click backlog is bounded")
        print("Passed \(checks) native command-delivery checks.")
    }
}
