import AppKit
@preconcurrency import ApplicationServices
import os

/// Minimizes the other profiles' windows and brings the current profile's back, for "Minimize other
/// profiles' windows" (#42), through Accessibility on ProfileReader's queue, one window at a time.
///
/// What to do comes from MinimizeRules; this reads Safari's windows and carries it out. Each window is a
/// work item of its own on the queue, so what's queued meanwhile (reading a new window's profile, a switch)
/// doesn't wait for the whole sweep, and a newer change stops a sweep before its next window, as the
/// generation counter does for switches.
///
/// It owns the list of windows Side Tabs minimized, and reports each change to it (`onListChanged`), so
/// SafariProfiles can save it. Only used on `reader.queue`, apart from `supersede` and `isLatest`.
nonisolated final class WindowMinimizer: @unchecked Sendable {
    /// A change of profile, gathered on the main thread.
    struct Sweep: @unchecked Sendable {
        let application: AXUIElement
        /// The profile now current.
        let current: UUID
        /// The profile it changed from, whose frontmost window is noted as used last.
        let left: UUID?
        /// The window in front, the target of the change, which is never touched. A switch fills it in
        /// once the window is Safari's main window.
        var front: Int?
        let reason: MinimizeReason
        /// Which profile a window belongs to, with what the app knew.
        let resolve: ProfileResolver
        /// Runs on the reader's queue when the sweep is over.
        let completion: @Sendable (Outcome) -> Void
    }

    /// What a sweep did, for the log and the Dock icon rule.
    struct Outcome: Sendable {
        var reason: MinimizeReason
        var current: UUID?
        /// The profile of each window minimized, and of each brought back.
        var minimized: [UUID] = []
        var restored: [UUID] = []
        /// Windows Safari didn't minimize or bring back: the next change tries again.
        var notMinimized = 0
        var notRestored = 0
        /// Windows that came off the list before the sweep: closed, or brought back by the user.
        var closed = 0
        var broughtBackByUser = 0
        /// The front window was raised again after the last window came back.
        var raisedFrontAgain = false
        /// A newer change stopped it.
        var superseded = false
        /// Safari didn't answer for every window, so none came off the list for having closed.
        var incompleteRead = false
        /// How the saved list was matched, when this sweep matched it.
        var matched: String?
        var milliseconds = 0
        /// Safari's windows once it's done, as far as known, for the Dock icon rule. Nil if not read.
        var windows: [ProfileWindow]?
    }

    /// How long Safari is given to answer a minimize or an un-minimize, which may wait for the animation:
    /// an unknown the live test settles. A window it doesn't answer for in time still goes on the list,
    /// since Safari carries out the request once it gets to it; if it didn't, the next change minimizes it
    /// again.
    static let minimizeTimeout: TimeInterval = 1.5
    /// Raise the front window again after the last window comes back, if one came up in front of it: an
    /// unknown the live test settles (whether the animation draws over the front window).
    static let raisesFrontAfterRestoring = true

    private let reader: ProfileReader
    private var query: AXQuery { reader.query }
    private let slowQuery = AXQuery(timeout: WindowMinimizer.minimizeTimeout)
    private let latest = OSAllocatedUnfairLock(initialState: 0)
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "profiles")

    // Only used on `reader.queue`.
    /// The windows Side Tabs minimized.
    private(set) var list = MinimizedList()
    /// A saved list not matched yet against Safari's windows: from before a restart of Side Tabs (same
    /// Safari) or of Safari. Matched at the next complete read.
    private var unmatched: (list: MinimizedList, sameSafari: Bool)?
    /// Windows minimized or brought back a moment ago, whose animation may not be over.
    private var inFlight: [Int: WindowInFlight] = [:]
    /// Set once, before the first sweep.
    var onListChanged: (@Sendable (MinimizedList) -> Void)?

    init(reader: ProfileReader) {
        self.reader = reader
    }

    // MARK: - Generations

    /// A new change: any sweep in progress stops before its next window. Any thread.
    func supersede() -> Int {
        latest.withLock { value -> Int in
            value += 1
            return value
        }
    }

    func isLatest(_ generation: Int) -> Bool {
        latest.withLock { $0 } == generation
    }

    // MARK: - The list

    /// The saved list, at launch. For the same Safari its window numbers still apply, so a switch can use it
    /// right away; after a restart of Safari it waits to be matched by UUID. Call on `reader.queue`.
    func load(_ saved: MinimizedList, sameSafari: Bool) {
        unmatched = (saved, sameSafari)
        list = sameSafari ? saved : MinimizedList()
    }

    /// Safari quit: its window numbers mean nothing now, so the list waits to be matched against the next
    /// Safari's windows by UUID. The file keeps it meanwhile. Call on `reader.queue`.
    func safariQuit() {
        if !list.isEmpty {
            unmatched = (list, false)
        } else if let pending = unmatched {
            unmatched = (pending.list, false)
        }
        list = MinimizedList()
        inFlight = [:]
    }

    /// Turning the setting on: windows already minimized count as the user's. Call on `reader.queue`.
    func clear() {
        unmatched = nil
        inFlight = [:]
        setList(MinimizedList())
    }

    /// Whether Side Tabs brought this window back a moment ago (a switch's target, or a sweep's), so its coming
    /// back isn't a change the user made (#44). Call on `reader.queue`.
    func restoredJustNow(_ number: Int) -> Bool {
        guard let flight = inFlight[number], !flight.minimized else { return false }
        return Date().timeIntervalSince(flight.at) < MinimizeRules.animationAllowance
    }

    /// A switch has just un-minimized its target: it comes off the list, and counts as open while its
    /// animation plays. Call on `reader.queue`.
    func broughtBack(_ number: Int) {
        inFlight[number] = WindowInFlight(minimized: false, at: Date())
        var updated = list
        updated.remove(number)
        setList(updated)
    }

    private func setList(_ new: MinimizedList) {
        guard new != list else { return }
        list = new
        onListChanged?(new)
    }

    // MARK: - Reading

    /// Safari's browser windows, front to back, as the rules need them, with each one's element and whether
    /// Safari answered for all of them. Call on `reader.queue`.
    func readWindows(application: AXUIElement, resolve: ProfileResolver) -> (windows: [ProfileWindow], elements: [Int: AXUIElement], complete: Bool) {
        let read = reader.windowsRead(application: application)
        var elements: [Int: AXUIElement] = [:]
        let windows = read.windows.map { info -> ProfileWindow in
            elements[info.number] = info.element
            return ProfileWindow(
                number: info.number,
                uuid: ProfileIdentifiers.windowUUID(info.identifier),
                profile: resolve(info.toolbar, info.title),
                isMinimized: info.isMinimized,
                isFullScreen: info.isFullScreen,
                // A minimized window is on no desktop; it doesn't matter where it was.
                isOnShownSpace: info.isMinimized || SafariTracker.isOnShownSpace(windowNumber: info.number)
            )
        }
        return (windows, elements, read.complete)
    }

    /// Matches a saved list against a complete read, once. Call on `reader.queue`.
    private func matchIfNeeded(_ windows: [ProfileWindow], complete: Bool, current: UUID?, outcome: inout Outcome) {
        guard let pending = unmatched, complete else { return }
        unmatched = nil
        let matched = MinimizeRules.matched(pending.list, sameSafari: pending.sameSafari, windows: windows, current: current)
        let how: String
        if pending.sameSafari {
            how = "the same Safari, by window number"
        } else if pending.list.isEmpty {
            how = "nothing saved"
        } else if MinimizeRules.uuidsSurvive(pending.list, windows: windows) {
            how = "Safari restarted; by UUID"
        } else {
            how = "Safari restarted and no UUID survived; every minimized window of another profile"
        }
        outcome.matched = "\(how): \(matched.windows.count) of \(pending.list.windows.count) saved"
        setList(matched)
    }

    // MARK: - Sweeping

    private enum Step {
        case minimize(Int, usedLast: Bool)
        case restore(Int)
        /// Raise this window again if another came up in front of it.
        case raiseFront(Int)
    }

    /// A sweep's steps, carried from one work item to the next.
    private struct Run: @unchecked Sendable {
        var steps: [Step]
        var next = 0
        let application: AXUIElement
        let elements: [Int: AXUIElement]
        var windows: [ProfileWindow]
        let generation: Int
        let started: Date
        var outcome: Outcome
        /// Turning the setting off: the list is cleared once it's done.
        let clearsList: Bool
        let completion: @Sendable (Outcome) -> Void

        mutating func setMinimized(_ number: Int, _ minimized: Bool) {
            guard let index = windows.firstIndex(where: { $0.number == number }) else { return }
            windows[index].isMinimized = minimized
        }
    }

    /// A change of profile: reads Safari's windows, takes off the list the ones that closed or that the user
    /// brought back, then minimizes and brings back what MinimizeRules.plan says. The first window is done
    /// right away, so a switch's sweep starts with no delay once its window is main. Call on `reader.queue`.
    func sweep(_ sweep: Sweep, generation: Int) {
        let started = Date()
        var outcome = Outcome(reason: sweep.reason, current: sweep.current)
        guard isLatest(generation) else {
            outcome.superseded = true
            sweep.completion(outcome)
            return
        }
        let read = readWindows(application: sweep.application, resolve: sweep.resolve)
        matchIfNeeded(read.windows, complete: read.complete, current: sweep.current, outcome: &outcome)
        let windows = settledWindows(read.windows, now: started)
        reconcile(windows, complete: read.complete, outcome: &outcome)
        let plan = MinimizeRules.plan(current: sweep.current, left: sweep.left, front: sweep.front, windows: windows, list: list)
        var steps = plan.minimize.map { Step.minimize($0, usedLast: plan.usedLast.contains($0)) } + plan.restore.map(Step.restore)
        if !plan.restore.isEmpty, Self.raisesFrontAfterRestoring, let front = sweep.front {
            steps.append(.raiseFront(front))
        }
        run(Run(steps: steps, application: sweep.application, elements: read.elements, windows: windows, generation: generation,
                started: started, outcome: outcome, clearsList: false, completion: sweep.completion))
    }

    /// Turning the setting off: every window on the list comes back at its own spot, behind Safari's front
    /// window, and the list is cleared. Windows the user minimized stay minimized. Call on `reader.queue`.
    func restoreAll(application: AXUIElement, current: UUID?, resolve: ProfileResolver,
                    generation: Int, completion: @escaping @Sendable (Outcome) -> Void) {
        let started = Date()
        var outcome = Outcome(reason: .settingOff, current: current)
        guard isLatest(generation) else {
            outcome.superseded = true
            completion(outcome)
            return
        }
        let read = readWindows(application: application, resolve: resolve)
        matchIfNeeded(read.windows, complete: read.complete, current: current, outcome: &outcome)
        let windows = settledWindows(read.windows, now: started)
        reconcile(windows, complete: read.complete, outcome: &outcome)
        var steps = MinimizeRules.restoreAll(list, windows: windows).map(Step.restore)
        query.clearTimedOut()
        if !steps.isEmpty, Self.raisesFrontAfterRestoring,
           let main = query.element(application, kAXMainWindowAttribute), let front = reader.number(of: main) {
            steps.append(.raiseFront(front))
        }
        run(Run(steps: steps, application: application, elements: read.elements, windows: windows, generation: generation,
                started: started, outcome: outcome, clearsList: true, completion: completion))
    }

    /// Safari's windows as they will be once the animations Side Tabs started are over.
    private func settledWindows(_ windows: [ProfileWindow], now: Date) -> [ProfileWindow] {
        inFlight = inFlight.filter { now.timeIntervalSince($0.value.at) < MinimizeRules.animationAllowance }
        return MinimizeRules.settled(windows, inFlight: inFlight, now: now)
    }

    private func reconcile(_ windows: [ProfileWindow], complete: Bool, outcome: inout Outcome) {
        guard complete else {
            outcome.incompleteRead = true
            return
        }
        let reconciled = MinimizeRules.reconciled(list, with: windows)
        let listed = Set(windows.map(\.number))
        for entry in list.windows where !reconciled.contains(entry.number) {
            if listed.contains(entry.number) {
                outcome.broughtBackByUser += 1
            } else {
                outcome.closed += 1
            }
        }
        setList(reconciled)
    }

    private func run(_ run: Run) {
        var run = run
        guard run.next < run.steps.count else {
            finish(run)
            return
        }
        guard isLatest(run.generation) else {
            run.outcome.superseded = true
            finish(run)
            return
        }
        perform(run.steps[run.next], in: &run)
        run.next += 1
        reader.queue.async { [self, run] in self.run(run) }
    }

    private func finish(_ run: Run) {
        var outcome = run.outcome
        if run.clearsList, !outcome.superseded {
            setList(MinimizedList())
        }
        outcome.milliseconds = Int(Date().timeIntervalSince(run.started) * 1000)
        outcome.windows = run.windows
        run.completion(outcome)
    }

    private func perform(_ step: Step, in run: inout Run) {
        switch step {
        case .minimize(let number, let usedLast):
            guard let element = run.elements[number],
                  let window = run.windows.first(where: { $0.number == number }),
                  let profile = window.profile.profileID else { return }
            switch setMinimized(true, element) {
            case .done:
                inFlight[number] = WindowInFlight(minimized: true, at: Date())
                var updated = list
                updated.add(number, uuid: window.uuid, profile: profile, usedLast: usedLast)
                setList(updated)
                run.setMinimized(number, true)
                run.outcome.minimized.append(profile)
            case .already:
                break
            case .failed:
                run.outcome.notMinimized += 1
            }
        case .restore(let number):
            guard let element = run.elements[number], let entry = list.windows.first(where: { $0.number == number }) else { return }
            switch setMinimized(false, element) {
            case .done:
                inFlight[number] = WindowInFlight(minimized: false, at: Date())
                var updated = list
                updated.remove(number)
                setList(updated)
                run.setMinimized(number, false)
                run.outcome.restored.append(entry.profile)
            case .already:
                // Back already: the user brought it back.
                var updated = list
                updated.remove(number)
                setList(updated)
                run.setMinimized(number, false)
            case .failed:
                run.outcome.notRestored += 1
            }
        case .raiseFront(let number):
            guard let element = run.elements[number] else { return }
            query.clearTimedOut()
            if let main = query.element(run.application, kAXMainWindowAttribute), reader.number(of: main) == number {
                return
            }
            // Within Safari only: Safari isn't brought forward, since the user may be elsewhere (in Side
            // Tabs' Settings, turning the setting off).
            query.perform(element, kAXRaiseAction)
            query.set(element, kAXMainAttribute, kCFBooleanTrue)
            run.outcome.raisedFrontAgain = true
        }
    }

    private enum StepResult {
        case done
        /// It already was so, or it's full screen now.
        case already
        case failed
    }

    /// Minimizes or un-minimizes a window, after looking at it once more: the plan may be a few windows old.
    private func setMinimized(_ minimized: Bool, _ window: AXUIElement) -> StepResult {
        query.clearTimedOut()
        guard let state = query.copyMultiple(window, [kAXMinimizedAttribute, "AXFullScreen"]), state.count == 2 else {
            // Closed, or Safari didn't answer: the next change tries again.
            return .failed
        }
        if (state[0] as? Bool ?? false) == minimized || (minimized && state[1] as? Bool == true) {
            return .already
        }
        slowQuery.clearTimedOut()
        let error = slowQuery.set(window, kAXMinimizedAttribute, minimized ? kCFBooleanTrue : kCFBooleanFalse)
        return error == .success || error == .cannotComplete ? .done : .failed
    }
}
