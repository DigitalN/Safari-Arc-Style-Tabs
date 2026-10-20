import Foundation

/// Short-lived commands for a running Safari session. A lost reply is retried with
/// the same ID; JavaScript acknowledges and deduplicates before executing it.
final class ExtensionCommandQueue {
    static let transport = "queue-v1"
    static let lifetime: TimeInterval = 15
    private struct Pending {
        var id: String
        var command: [String: Any]
        var expires: Date
        var acknowledgedBy: Set<String> = []
    }
    private var pending: [Pending] = []

    func enqueue(_ command: [String: Any], now: Date = Date()) {
        pending.removeAll { $0.expires <= now }
        // Never replay an unbounded backlog of clicks after a disconnection.
        guard pending.count < 256 else { return }
        pending.append(Pending(id: UUID().uuidString, command: command,
                               expires: now.addingTimeInterval(Self.lifetime)))
    }

    func reply(to message: [String: Any], now: Date = Date()) -> [[String: Any]] {
        pending.removeAll { $0.expires <= now }
        // Older background scripts lack deduplication; do not send retryable commands.
        guard message["commandTransport"] as? String == Self.transport,
              let instance = message["instance"] as? String, !instance.isEmpty else { return [] }
        let acks = Set(message["commandAcks"] as? [String] ?? [])
        for index in pending.indices {
            let target = pending[index].command["instance"] as? String
            if acks.contains(pending[index].id), target == nil || target == instance {
                pending[index].acknowledgedBy.insert(instance)
            }
        }
        pending.removeAll { item in
            (item.command["instance"] as? String).map { item.acknowledgedBy.contains($0) } ?? false
        }
        return pending.compactMap { item in
            let target = item.command["instance"] as? String
            guard (target == nil || target == instance), !item.acknowledgedBy.contains(instance) else { return nil }
            var command = item.command
            command["commandID"] = item.id
            return command
        }
    }
}
