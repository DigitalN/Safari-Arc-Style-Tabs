import Foundation

// How often the dock looks at Safari's window again for the changes macOS doesn't announce, and what
// each look reads (#78). Kept apart from AppKit so the rules can be checked without Safari
// (Tests/HealthCheckChecks): DockController feeds in the settings, Safari's state and the holds, and runs
// the timer.
//
// What the looks catch, while Safari is in front, within about two seconds: Safari windows appearing and
// a switch to another window that the notifications missed (the full read, which picks the window again),
// a swipe toward another Space that's taken back, leaving full screen finishing after the last event about
// it, Safari's bars coming and going without the window moving (#35), and another window ending up between
// Safari's window and the sidebar. Accessibility access being granted relaunches the app
// (AccessibilityWatcher).
//
// Every read is answered on Safari's main thread, so a look wakes Safari too. None run while there's
// nothing to keep in place: the sidebar turned off, Safari not running, or a hold (asleep, the displays
// asleep, the screen locked, the screen saver, the session switched away, Safari hidden).
//
// Nor while another app is in front. The sidebar can't come out over Safari then, so its bars don't matter,
// nor does what's stacked between the two windows. Missed window switches and full screen finishing late
// can only be seen by asking Safari, which a look mustn't do while it's behind. What's left, the last frame
// read and the Spaces of the two windows, changes only on what the tracker already lays the sidebar out
// for: the docked window's notifications (moved, resized, closed, minimized), Safari's (a window focused,
// created, hidden or shown), a change of Space, and Safari coming to the front, which reads everything again
// at once and starts the looks with one that picks the window.

nonisolated enum HealthCheck {
    /// How often the looks run, or why they don't.
    enum Cadence: Equatable {
        /// No timer. The reason is for the log.
        case off(String)
        /// Safari is the frontmost app: the sidebar can come out over it, and it's being used.
        case safariInFront

        /// Seconds between looks; nil when there's no timer.
        var interval: TimeInterval? {
            switch self {
            case .off: nil
            case .safariInFront: 1
            }
        }

        /// How late macOS may run a look, so it can line it up with other wakeups. At least 10% of the
        /// interval.
        var tolerance: TimeInterval {
            (interval ?? 0) * 0.2
        }

        var isRunning: Bool { interval != nil }

        /// For the log.
        var summary: String {
            switch self {
            case .off(let reason): "off: \(reason)"
            case .safariInFront: "every 1 s, Safari in front"
            }
        }
    }

    /// Whether looks run, and how often. `holds` are HoldWatcher's.
    static func cadence(sidebarVisible: Bool, safariRunning: Bool, holds: Set<CopySilence.Hold>, safariInFront: Bool) -> Cadence {
        if !sidebarVisible {
            return .off("sidebar turned off")
        }
        if !safariRunning {
            return .off("Safari not running")
        }
        if !holds.isEmpty {
            return .off(CopySilence.describe(holds))
        }
        return safariInFront ? .safariInFront : .off("Safari in the background")
    }

    /// What one look reads of Safari's window. Every look also attaches if the tracker isn't attached, reads
    /// Safari's bars where they're read at all (full screen, or the sidebar hiding automatically), and checks
    /// whether another window is between Safari's window and the sidebar.
    enum Read: Equatable {
        /// The docked window's frame, title and full-screen state, in one round trip.
        case geometry
        /// Which window to dock to as well: the focused window and its traits, and the main window if the
        /// focused one isn't a browser window.
        case full
    }

    /// Every this many looks picks the window again, so a switch the notifications missed is caught within
    /// about two seconds.
    static let fullReadEvery = 2

    /// What the next look reads. `looksSinceFullRead`: looks since the last one that picked the window.
    /// `fullReadDue`: something asked for the window to be picked again (the looks starting again after
    /// they were off, say). `hasWindow`: the tracker knows a window to dock to. Nil when no look runs.
    static func look(cadence: Cadence, looksSinceFullRead: Int, fullReadDue: Bool, hasWindow: Bool) -> Read? {
        guard cadence.isRunning else { return nil }
        return fullReadDue || !hasWindow || looksSinceFullRead + 1 >= fullReadEvery ? .full : .geometry
    }

    /// When the looks last picked the window again, and what the next one reads.
    struct Schedule: Equatable {
        private(set) var looksSinceFullRead = 0
        /// Something asked for the window to be picked again at the next look.
        private(set) var fullReadDue = true

        /// The looks start again after they were off: what changed meanwhile wasn't seen.
        mutating func resume() {
            fullReadDue = true
        }

        /// The next look, and counts it. Nil when no look runs.
        mutating func next(cadence: Cadence, hasWindow: Bool) -> Read? {
            guard let read = HealthCheck.look(cadence: cadence, looksSinceFullRead: looksSinceFullRead,
                                              fullReadDue: fullReadDue, hasWindow: hasWindow) else { return nil }
            switch read {
            case .full:
                fullReadDue = false
                looksSinceFullRead = 0
            case .geometry:
                looksSinceFullRead += 1
            }
            return read
        }
    }
}
