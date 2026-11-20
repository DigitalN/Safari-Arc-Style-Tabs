// Checks for AppPort, the extension's way to the app (SideTabsExtension/SafariWebExtensionHandler.swift),
// against a stand-in for the app's port, registered under a name of its own: nothing here reaches the real app.
//
// scripts/run-checks.sh compiles this together with the handler and runs it. It takes about 10 s: the
// stalled-app checks wait for real time-outs.

import Foundation

nonisolated(unsafe) var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

/// How long the stand-in app takes over a message whose text starts with "stall".
nonisolated(unsafe) var stallSeconds: TimeInterval = 0
/// How many messages the stand-in app has answered.
nonisolated(unsafe) var answered = 0

/// A stand-in for the app: a local port that answers each message with its own text, on a thread of its own,
/// one message at a time, as the app does on its main thread.
final class StandInApp {
    let port: CFMessagePort
    private var runLoop: CFRunLoop?

    init?(name: String) {
        let callback: CFMessagePortCallBack = { _, _, data, _ in
            let text = data.map { String(decoding: $0 as Data, as: UTF8.self) } ?? ""
            if text.hasPrefix("stall") { Thread.sleep(forTimeInterval: stallSeconds) }
            answered += 1
            return data.map { Unmanaged.passRetained($0) }
        }
        var shouldFree: DarwinBoolean = false
        guard let port = CFMessagePortCreateLocal(nil, name as CFString, callback, nil, &shouldFree) else { return nil }
        self.port = port
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        let ready = DispatchSemaphore(value: 0)
        Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }.start()
        ready.wait()
    }

    /// The app quitting.
    func quit() {
        CFMessagePortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}

/// Sends `text` through AppPort, timed.
func send(_ text: String) -> (reply: String?, seconds: TimeInterval) {
    let start = Date()
    let reply = AppPort.send(Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    return (reply, Date().timeIntervalSince(start))
}

/// Sends each of `texts` from a thread of its own, `spacing` apart, and waits for all of them.
func sendAtOnce(_ texts: [String], spacing: TimeInterval = 0.05) -> [(reply: String?, seconds: TimeInterval)] {
    let lock = NSLock()
    var results = [(reply: String?, seconds: TimeInterval)?](repeating: nil, count: texts.count)
    let group = DispatchGroup()
    for (i, text) in texts.enumerated() {
        group.enter()
        Thread {
            let result = send(text)
            lock.withLock { results[i] = result }
            group.leave()
        }.start()
        Thread.sleep(forTimeInterval: spacing)
    }
    group.wait()
    return results.map { $0! }
}

let name = "sidetabs.appport-checks.\(getpid())"
AppPort.portName = name

// With no app, a message gives up at once.
do {
    let (reply, seconds) = send("hello")
    check(reply == nil && seconds < 0.5, "with the app not running, a message gets no reply, at once (\(seconds) s)")
    check(AppPort.keptPort == nil, "and no port is kept")
}

guard var app = StandInApp(name: name) else {
    print("FAIL: couldn't register the stand-in app's port")
    exit(1)
}

// The port is looked up once and kept.
do {
    let first = send("one")
    check(first.reply == "one", "a message gets the app's reply (\(first.reply ?? "nil"))")
    let kept = AppPort.keptPort
    check(kept != nil, "the port is kept")
    let second = send("two")
    check(second.reply == "two", "the next message gets its reply too")
    check(AppPort.keptPort === kept, "through the same port, not one looked up again")
}

// Messages from several threads at once each get their own reply, through the one port.
do {
    let texts = (0..<24).map { "message \($0)" }
    let results = sendAtOnce(texts, spacing: 0.002)
    check(zip(texts, results).allSatisfy { $0 == $1.reply }, "messages sent at once each get their own reply")
    let slowest = results.map(\.seconds).max() ?? 0
    check(slowest < 1, "none of them waits for a time-out (slowest \(slowest) s)")
}

// While the app is stalled, messages don't queue behind each other: each times out on its own clock, within
// background.js's 4 s limit. Queued one after another, the third would have taken 2 s + 2 s + 2 s.
do {
    stallSeconds = 4.5
    let results = sendAtOnce(["stall", "after it", "and another"])
    for (text, result) in zip(["stall", "after it", "and another"], results) {
        check(result.reply == nil && result.seconds < AppPort.timeLimit + 0.1,
              "while the app is stalled, \"\(text)\" gives up within the time limit (\(result.seconds) s)")
    }
    check(results.map(\.seconds).max()! < AppPort.replyTimeout + AppPort.sendTimeout,
          "each on its own clock, not after the ones before it (\(results.map(\.seconds)))")
    check(AppPort.keptPort != nil, "a time-out keeps the port")
    // The stand-in works through what queued up, then answers again.
    Thread.sleep(forTimeInterval: 2.5)
    stallSeconds = 0
    check(send("awake").reply == "awake", "once the app answers again, so does the kept port")
}

// The app quitting and starting again: its new port is found, and the message that found the old one gone
// is sent again and gets its reply.
do {
    let old = AppPort.keptPort
    app.quit()
    Thread.sleep(forTimeInterval: 0.2)
    guard let relaunched = StandInApp(name: name) else {
        print("FAIL: couldn't register the relaunched stand-in app's port")
        exit(1)
    }
    app = relaunched
    let (reply, seconds) = send("after relaunch")
    check(reply == "after relaunch", "after the app relaunches, the next message reaches it (\(reply ?? "nil"))")
    check(seconds < 1, "without waiting for a time-out (\(seconds) s)")
    check(AppPort.keptPort != nil && AppPort.keptPort !== old, "through its new port, which is kept")
}

// The app quitting for good: the next message gets no reply, at once, and nothing is kept.
do {
    app.quit()
    Thread.sleep(forTimeInterval: 0.2)
    let (reply, seconds) = send("anyone?")
    check(reply == nil && seconds < 0.5, "with the app gone, a message gets no reply, at once (\(seconds) s)")
    check(AppPort.keptPort == nil, "and the dead port isn't kept")
}

if failures == 0 {
    print("app port checks passed")
    exit(0)
}
print("\(failures) app port check(s) failed")
exit(1)
