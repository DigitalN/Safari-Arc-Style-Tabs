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

    /// How long the cross-fade takes: about as long as the window's slide-in from the Dock, kept short. The
    /// Scale effect is quicker than the Genie (the Dock's `mineffect`).
    static func fadeDuration(minimizeEffect: String?) -> TimeInterval {
        minimizeEffect == "scale" ? 0.25 : 0.35
    }
}
