import Foundation

// What the sidebar shows while a profile switch's window comes back from the Dock (#44), kept apart from
// Accessibility and SwiftUI so the checks can run it (Tests/SwitchPreviewChecks).
//
// The sidebar follows what Safari reports, and Safari only reports the new window once its un-minimize
// animation is over. So at the click the sidebar shows its guess at once: the target profile's Favorites and
// Pinned, and the tabs of the window the switch brings forward, matched to a window of the profile's
// extension copy with only what the store already has. When that can't be told, the profile's lists and a
// placeholder for Tabs: never another window's tabs. Once Safari reports, the sidebar's own choice takes over,
// with no second fade.

/// The window a switch brings forward, as far as it's known.
nonisolated struct SwitchTarget: Equatable, Sendable {
    /// The profile switched to, as its copy's snapshots name it.
    let profile: ProfileKey
    /// Safari's title for the target window ("<profile> — <page>"), once the switch has picked the window
    /// through Accessibility. Nil before that. Never logged.
    var title: String?
    /// The profile has no window: the switch opens one from File → New Window.
    var isNewWindow = false
    /// How many of Safari's browser windows are the profile's, from their toolbars, when known.
    var profileWindowCount: Int?

    init(profile: ProfileKey, title: String? = nil, isNewWindow: Bool = false, profileWindowCount: Int? = nil) {
        self.profile = profile
        self.title = title
        self.isNewWindow = isNewWindow
        self.profileWindowCount = profileWindowCount
    }
}

/// What the sidebar shows for a switch's profile until Safari reports: also, in the same terms, what the
/// sidebar shows once it has.
nonisolated enum SwitchGuess: Equatable, Sendable {
    /// This window of the profile's copy.
    case window(instance: String, windowId: Int)
    /// The profile's lists, and a placeholder for Tabs: which window isn't known.
    case placeholder
    /// A window the profile's copy can't see (#41): the profile's lists, and the window's tabs from its tab bar.
    case unseen
}

nonisolated enum SwitchPreviewRules {
    /// A guess Safari hasn't confirmed after this long gives way to what the sidebar would show anyway.
    static let lifetime: TimeInterval = 3

    /// The window of the target profile's copy that the switch brings forward, from what the store has:
    ///
    /// - With the target's title (once the switch has picked it), the copy's window whose active tab fits the
    ///   title, by the rules `TabStore.currentWindow` uses: the title is the page's, after "<profile> — ".
    ///   Of windows on the same page, the copy's last focused one; otherwise it can't be told.
    /// - Before that, the copy's last focused window: a switch brings forward the profile's window used last,
    ///   which is the one its copy last had focused. Or its only window.
    /// - A copy that lists no window on the target's page, while Safari has more of the profile's windows than
    ///   the copy lists, can't see the target (#41).
    /// - A new window, a profile with no live copy, or anything else that can't be told: a placeholder.
    ///
    /// Private windows are no profile's, and never the target.
    static func guess(_ target: SwitchTarget, copies: [Snapshot]) -> SwitchGuess {
        guard !target.isNewWindow else { return .placeholder }
        let own = copies
            .filter { ProfileKey(snapshotProfile: $0.profile) == target.profile }
            .sorted { $0.focusChangedAt > $1.focusChangedAt }
        let windows = own.flatMap { snapshot in
            snapshot.windows.filter { !$0.incognito }.map { (instance: snapshot.instance, window: $0) }
        }
        let lastFocused: [(instance: String, windowId: Int)] = own.compactMap { snapshot in
            let id = (snapshot.focusedWindowId ?? -1) >= 0 ? snapshot.focusedWindowId : snapshot.lastFocusedWindowId
            guard let id, snapshot.windows.contains(where: { $0.id == id && !$0.incognito }) else { return nil }
            return (snapshot.instance, id)
        }

        if let title = target.title, !title.isEmpty {
            var fitting: [(instance: String, windowId: Int, length: Int)] = []
            for (instance, window) in windows {
                guard let active = window.tabs.first(where: \.active)?.title, !active.isEmpty,
                      active == title || title.hasSuffix(" — " + active) else { continue }
                fitting.append((instance, window.id, active.count))
            }
            // A page title can contain " — " itself, so a shorter one in another window can fit too.
            let longest = fitting.map(\.length).max()
            let best = fitting.filter { $0.length == longest }
            if best.count == 1 {
                return .window(instance: best[0].instance, windowId: best[0].windowId)
            }
            if !best.isEmpty {
                let recent = lastFocused.first { focused in best.contains { $0.instance == focused.instance && $0.windowId == focused.windowId } }
                return recent.map { .window(instance: $0.instance, windowId: $0.windowId) } ?? .placeholder
            }
            if let count = target.profileWindowCount, !own.isEmpty, windows.count < count {
                return .unseen
            }
            return .placeholder
        }

        if let recent = lastFocused.first {
            return .window(instance: recent.instance, windowId: recent.windowId)
        }
        if windows.count == 1 {
            return .window(instance: windows[0].instance, windowId: windows[0].window.id)
        }
        return .placeholder
    }

    /// Whether the sidebar shows its guess at once, cross-fading to it: only when the window comes back from
    /// the Dock. Before the switch has picked its target (`targetIsMinimized` nil), the setting decides: with
    /// it on, the target is nearly always minimized. A switch to a window that's already open stays as it
    /// was, with no fade and no guess: Safari reports it in about 0.1 s.
    static func fades(targetIsMinimized: Bool?, minimizesOtherProfiles: Bool) -> Bool {
        targetIsMinimized ?? minimizesOtherProfiles
    }

    /// What Safari's report did to a guess.
    enum Report: Equatable, Sendable {
        /// The sidebar keeps what it showed.
        case kept
        /// The sidebar changes to the window Safari reported, with no second fade.
        case corrected
    }

    /// A guess against what the sidebar shows once Safari has reported the switch's window.
    static func report(_ guess: SwitchGuess, shown: SwitchGuess) -> Report {
        guess == shown && guess != .placeholder ? .kept : .corrected
    }

    // MARK: - The fade's timing

    // The old contents fade fully out, then the new fade in, so the two are never on screen together; the
    // new are fully in about as the window lands.

    /// How long the old contents take to fade out: short, so the new can start coming in.
    static let fadeOut: TimeInterval = 0.12
    /// The shortest fade-in, for a window that has landed already, or nearly.
    static let shortestFadeIn: TimeInterval = 0.15
    /// How long after its start a fade for a window that's already on its way (a Dock tile, the Window menu,
    /// App Exposé) is given: Side Tabs only hears of it once the window's animation has begun.
    static let alreadyOnItsWay: TimeInterval = 0.5

    /// How long after the click a minimized window lands, until a switch has measured it: the Genie effect
    /// takes about 0.76 s here (#44's live test), the Scale effect less (the Dock's `mineffect`).
    static func arrivalEstimate(minimizeEffect: String?) -> TimeInterval {
        minimizeEffect == "scale" ? 0.5 : 0.76
    }

    /// The estimate after a switch that measured how long its minimized window took to become Safari's main
    /// window: halfway to the new measure, so one slow switch doesn't throw it off, and within reason.
    static func arrivalEstimate(after previous: TimeInterval, measured: TimeInterval) -> TimeInterval {
        min(max((previous + measured) / 2, 0.3), 1.5)
    }

    /// How long the new contents take to fade in, once the old are out at `now`: until the window lands.
    static func fadeIn(arrivesAt arrival: Date, now: Date) -> TimeInterval {
        max(shortestFadeIn, arrival.timeIntervalSince(now))
    }
}

// MARK: - The fade's steps

/// The sidebar's fade over to a switch's profile (#44), step by step, kept apart from SwiftUI and timers so the
/// checks can interrupt it anywhere. The sidebar draws one set of sections, never two: its opacity goes to 0 over
/// what was shown, the contents are swapped while nothing shows, and it comes back to 1, ending as the window
/// lands. The opacity always follows the phase, never an animation's progress, so a fade that's over shows the
/// sections at full opacity whatever an animation did on the way; and a watchdog ends any fade a moment after its
/// window should have landed, even if its other timers never fired.
nonisolated struct SidebarFade: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case none
        /// What was shown when the fade began is fading out, over this long.
        case out(TimeInterval)
        /// Out: the new contents take its place while nothing shows, with no animation.
        case hidden
        /// The new contents are fading in, over this long.
        case `in`(TimeInterval)
    }

    /// A timer to set. When it fires, `fire` it.
    struct Timer: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case outEnded, fadeIn, inEnded, watchdog
        }
        let kind: Kind
        /// The fade it belongs to: a timer of an earlier fade does nothing.
        let step: Int
        /// In seconds from now.
        let after: TimeInterval
    }

    private(set) var phase: Phase = .none
    /// Bumped by each new fade-out.
    private(set) var step = 0
    /// When the newest switch's window should land.
    private(set) var arrivesAt = Date.distantPast

    /// How long a fade may outlast its window before the watchdog ends it.
    static let grace: TimeInterval = 0.5
    /// Between the swap and the fade-in: the next turn, so the swap isn't part of an animation.
    static let swapPause: TimeInterval = 0.02
    /// After an animation's end, before its step is taken as done.
    static let margin: TimeInterval = 0.02

    /// The sections' opacity.
    var opacity: Double {
        switch phase {
        case .out, .hidden: 0
        case .none, .in: 1
        }
    }

    /// The sections keep showing what was there before the fade: only while it fades out.
    var showsOldContents: Bool {
        if case .out = phase { return true }
        return false
    }

    var isOver: Bool { phase == .none }

    /// A switch's window is on its way, landing at `arrivesAt`. Unless a fade-out is under way (then what's
    /// fading out is still what was there first, and the newest contents come in once it's out), a fade-out
    /// starts from whatever is on screen: nothing, the new contents fading in, or ones just swapped in.
    /// `keepsOnScreen`: the contents on screen now are the old ones, to keep while they fade out.
    mutating func begin(arrivesAt: Date, now: Date) -> (keepsOnScreen: Bool, timers: [Timer]) {
        self.arrivesAt = arrivesAt
        let watchdogAfter = max(arrivesAt.timeIntervalSince(now), 0) + Self.grace
        if case .out = phase {
            return (false, [Timer(kind: .watchdog, step: step, after: watchdogAfter)])
        }
        step += 1
        phase = .out(SwitchPreviewRules.fadeOut)
        return (true, [
            Timer(kind: .outEnded, step: step, after: SwitchPreviewRules.fadeOut + Self.margin),
            Timer(kind: .watchdog, step: step, after: watchdogAfter),
        ])
    }

    /// A timer has fired: the next step, and the timers it needs.
    mutating func fire(_ timer: Timer, now: Date) -> [Timer] {
        guard timer.step == step else { return [] }
        switch (timer.kind, phase) {
        case (.outEnded, .out):
            phase = .hidden
            return [Timer(kind: .fadeIn, step: step, after: Self.swapPause)]
        case (.fadeIn, .hidden):
            let duration = SwitchPreviewRules.fadeIn(arrivesAt: arrivesAt, now: now)
            phase = .in(duration)
            return [Timer(kind: .inEnded, step: step, after: duration + Self.margin)]
        case (.inEnded, .in):
            phase = .none
            return []
        case (.watchdog, let current) where current != .none:
            let left = arrivesAt.addingTimeInterval(Self.grace).timeIntervalSince(now)
            guard left <= 0.001 else {
                // A newer switch moved the landing on: look again then.
                return [Timer(kind: .watchdog, step: step, after: left)]
            }
            phase = .none
            return []
        default:
            return []
        }
    }
}
