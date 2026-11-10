import Foundation

// The rules behind the profile buttons (#33), kept apart from Accessibility and AppKit so the checks
// can run them (Tests/ProfileChecks): which profile a window belongs to, which extension copy is a
// profile's, when Side Tabs counts as off in a profile, and which window a switch brings forward.

/// A window as an extension copy's snapshot lists it: enough to tell which Safari window it is.
nonisolated struct CopyWindow: Equatable, Sendable {
    /// The copy's profile (`Snapshot.profile`).
    let key: ProfileKey
    let incognito: Bool
    /// The active tab's title, which Safari puts in the window's title after "<profile> — ".
    let activeTitle: String?
}

/// An extension copy, for the off rule.
nonisolated struct CopyState: Equatable, Sendable {
    let key: ProfileKey
    /// Sending heartbeats: not quiet (TabStore.liveInstances, #31), and not replaced.
    let isLive: Bool
    /// It lists the window in question (not as a private window).
    let reportsWindow: Bool
}

/// Which profile a window belongs to.
nonisolated enum ProfileResolution: Equatable, Sendable {
    case profile(UUID)
    /// Several profiles have the window's name, and nothing tells them apart yet.
    case ambiguous
    /// No profile has the window's name: the list is out of date.
    case unknownName
    /// A private window, which is no profile's, or a toolbar that couldn't be read.
    case noProfile

    var profileID: UUID? {
        if case .profile(let id) = self { return id }
        return nil
    }
}

/// Which profile a window belongs to (ProfileRules.resolve), with the profiles and copies' windows known when
/// it was made, for work done off the main thread.
nonisolated struct ProfileResolver: Sendable {
    let profiles: [SafariProfile]
    let copyWindows: [CopyWindow]

    func callAsFunction(_ toolbar: ToolbarProfile, _ windowTitle: String?) -> ProfileResolution {
        ProfileRules.resolve(toolbar, windowTitle: windowTitle, profiles: profiles, copyWindows: copyWindows)
    }
}

/// A Safari window, for choosing the one a switch brings forward.
nonisolated struct WindowFacts: Equatable, Sendable {
    let number: Int
    let profile: ProfileResolution
    let isMinimized: Bool
}

nonisolated enum ProfileRules {
    // MARK: - Which copy lists a window

    /// Whether Safari's title for a window of profile `profileName` fits a window whose active tab
    /// is titled `activeTitle`. Safari titles a profile's window "<profile> — <page>"; without
    /// profiles, just "<page>".
    static func fits(windowTitle: String?, profileName: String, activeTitle: String?) -> Bool {
        guard let windowTitle, let activeTitle, !activeTitle.isEmpty else { return false }
        if profileName.isEmpty {
            return windowTitle == activeTitle
        }
        let separator = " — "
        guard windowTitle.hasSuffix(separator + activeTitle) else { return false }
        let prefix = String(windowTitle.dropLast(activeTitle.count + separator.count))
        return ProfileIdentifiers.sameName(prefix, profileName)
    }

    /// The copies that list a window of profile `profileName` titled `windowTitle`. Private windows
    /// don't count: the default profile's copy lists them, whatever profile they were opened from.
    /// Copies in `excluded` are known to be other profiles', so they can't list this window, even if
    /// one of their windows has the same page (two profiles can share a name).
    static func copiesListing(windowTitle: String?, profileName: String, in windows: [CopyWindow], excluding excluded: Set<ProfileKey> = []) -> Set<ProfileKey> {
        Set(windows.filter { window in
            !window.incognito && !excluded.contains(window.key)
                && fits(windowTitle: windowTitle, profileName: profileName, activeTitle: window.activeTitle)
        }.map(\.key))
    }

    /// The key to learn for `profile` from its window titled `windowTitle`: the one copy that lists
    /// the window, among copies no other profile is known to have. Nil when none or several do, or
    /// when it can't be right (the default profile's copy for another profile, or the other way round).
    static func keyToLearn(for profile: SafariProfile, windowTitle: String?, in windows: [CopyWindow], profiles: [SafariProfile]) -> ProfileKey? {
        let othersKeys = Set(profiles.filter { $0.id != profile.id }.compactMap(\.key))
        let keys = copiesListing(windowTitle: windowTitle, profileName: profile.name, in: windows, excluding: othersKeys)
        guard keys.count == 1, let key = keys.first, key.isDefault == profile.isDefault, key != profile.key else { return nil }
        return key
    }

    // MARK: - Which profile a window belongs to

    /// The profile a window's toolbar names. A name only one profile has decides. Profiles sharing
    /// a name are told apart, in this order, by:
    /// 1. the symbol, once known, or by elimination when it's the only one whose symbol isn't known;
    /// 2. the one copy listing the window, when its key is known to be one of theirs;
    /// 3. the menu's ⌘N, which Safari gives the front window's profile (`newWindowShortcut` is that
    ///    item's position, from a menu read made for this window), only as a last resort.
    static func resolve(_ toolbar: ToolbarProfile, windowTitle: String?, profiles: [SafariProfile], copyWindows: [CopyWindow], newWindowShortcut: Int? = nil) -> ProfileResolution {
        guard case .profile(let name, let symbol) = toolbar else { return .noProfile }
        if name.isEmpty {
            // A profile button that names no profile: Safari without profiles.
            return profiles.count == 1 ? .profile(profiles[0].id) : .unknownName
        }
        let named = profiles.filter { ProfileIdentifiers.sameName($0.name, name) }
        if named.isEmpty {
            return .unknownName
        }
        if named.count == 1 {
            return .profile(named[0].id)
        }
        if let symbol {
            let same = named.filter { $0.symbol == symbol }
            if same.count == 1 {
                return .profile(same[0].id)
            }
            let unknown = named.filter { $0.symbol == nil }
            if same.isEmpty, unknown.count == 1 {
                return .profile(unknown[0].id)
            }
        }
        let namedIDs = Set(named.map(\.id))
        let othersKeys = Set(profiles.filter { !namedIDs.contains($0.id) }.compactMap(\.key))
        let keys = copiesListing(windowTitle: windowTitle, profileName: name, in: copyWindows, excluding: othersKeys)
        if keys.count == 1, let key = keys.first {
            let byKey = named.filter { $0.key == key }
            if byKey.count == 1 {
                return .profile(byKey[0].id)
            }
        }
        if let newWindowShortcut, profiles.indices.contains(newWindowShortcut), namedIDs.contains(profiles[newWindowShortcut].id) {
            return .profile(profiles[newWindowShortcut].id)
        }
        return .ambiguous
    }

    // MARK: - When Side Tabs is off in a profile

    /// How long a window has to have been open, with no copy listing it, before its profile counts
    /// as off. Copies report a new window within a second, even one that starts for it (#28).
    static let offAfter: TimeInterval = 2

    /// Whether Side Tabs counts as off in `profile`, from one of its windows that has been open for
    /// `windowOpenFor` seconds: long enough, no copy lists the window, and no copy of the profile
    /// is sending heartbeats. A running copy can miss windows that were open before it started (after
    /// a reinstall, #28), so its heartbeats alone keep the profile on.
    ///
    /// Copies known to be other profiles' don't count either way. While the profile's own copy isn't
    /// known yet, any live copy no profile is known to have could be it, and keeps it on.
    ///
    /// Never before the copies have had their chance to speak (`copiesHadTheirChance`, from
    /// TabStore.copiesHaveHadTheirChance): after Side Tabs starts or Safari launches, a profile's copy
    /// that hasn't spoken yet may only be late (#45).
    static func isOff(_ profile: SafariProfile, profiles: [SafariProfile], windowOpenFor: TimeInterval, copiesHadTheirChance: Bool, copies: [CopyState]) -> Bool {
        guard copiesHadTheirChance, windowOpenFor >= offAfter else { return false }
        let othersKeys = Set(profiles.filter { $0.id != profile.id }.compactMap(\.key))
        for copy in copies where copy.isLive && !othersKeys.contains(copy.key) {
            guard let key = profile.key else { return false }
            if copy.key == key || copy.reportsWindow {
                return false
            }
        }
        return true
    }

    // MARK: - Which window a switch brings forward

    /// Of Safari's windows, front to back, the one to bring forward for `profile`, in this order:
    /// 1. its frontmost open window, which is the one used last;
    /// 2. the window noted as used last when the profile was left (`usedLast`), which Side Tabs
    ///    minimized ("Minimize other profiles' windows", #42): once all of a profile's windows are
    ///    minimized, the order Accessibility lists them in says nothing about which was used last;
    /// 3. another window on Side Tabs' list of windows it minimized (`listed`);
    /// 4. a window the user minimized, only when the profile has no other.
    ///
    /// With the setting off the list is empty, and this is the frontmost open window, else a minimized
    /// one. Nil if the profile has no window, and a new one has to be opened.
    static func switchTarget(for profile: UUID, among windows: [WindowFacts], usedLast: Int? = nil, listed: Set<Int> = []) -> WindowFacts? {
        let own = windows.filter { $0.profile == .profile(profile) }
        return own.first(where: { !$0.isMinimized })
            ?? own.first(where: { $0.isMinimized && $0.number == usedLast && listed.contains($0.number) })
            ?? own.first(where: { $0.isMinimized && listed.contains($0.number) })
            ?? own.first
    }
}
