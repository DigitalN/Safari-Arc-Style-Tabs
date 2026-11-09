import Foundation

// The rules behind "Minimize other profiles' windows" (#42), kept apart from Accessibility and AppKit so
// the checks can run them (Tests/MinimizeChecks): the current profile, which windows a change of profile
// minimizes and which come back, the list of windows Side Tabs minimized and how it's matched after a
// restart, and when a click on Safari's Dock icon opens a window in the current profile. Which window a
// switch brings forward is ProfileRules.switchTarget, which takes what the list says.
//
// With the setting on, only the current profile's windows are open. Never touched: private windows,
// full-screen windows (macOS can't minimize them), windows on desktops not being shown, windows whose
// profile can't be told, and the window in front. A window the user minimized stays minimized: only
// windows on the list come back.

/// One of Safari's browser windows, as a change of profile needs to know it.
nonisolated struct ProfileWindow: Equatable, Sendable {
    /// The window server's number, which doesn't change while Safari runs.
    let number: Int
    /// The UUID in its `AXIdentifier` (`SafariWindow?IsSecure=…&UUID=…`), which may survive a relaunch.
    var uuid: String?
    /// `.profile` only when it's known; a private window and an unread toolbar are `.noProfile`.
    let profile: ProfileResolution
    var isMinimized = false
    var isFullScreen = false
    /// On a desktop being shown. Accessibility doesn't list windows on other desktops, so this is in case
    /// it does after all. Says nothing for a minimized window.
    var isOnShownSpace = true

    init(number: Int, uuid: String? = nil, profile: ProfileResolution, isMinimized: Bool = false, isFullScreen: Bool = false, isOnShownSpace: Bool = true) {
        self.number = number
        self.uuid = uuid
        self.profile = profile
        self.isMinimized = isMinimized
        self.isFullScreen = isFullScreen
        self.isOnShownSpace = isOnShownSpace
    }

    /// Open where the user can see it: not minimized, and on a desktop being shown.
    var isOpenHere: Bool { !isMinimized && isOnShownSpace }
}

/// A window Side Tabs minimized.
nonisolated struct MinimizedWindow: Codable, Equatable, Sendable {
    var number: Int
    var uuid: String?
    /// Side Tabs' id for its profile (`SafariProfile.id`).
    var profile: UUID
    /// It was in front when its profile was left: a switch to the profile brings it forward.
    var usedLast: Bool

    init(number: Int, uuid: String? = nil, profile: UUID, usedLast: Bool = false) {
        self.number = number
        self.uuid = uuid
        self.profile = profile
        self.usedLast = usedLast
    }
}

/// The windows Side Tabs minimized, in the order it minimized them. A minimized window that isn't on it
/// is the user's.
nonisolated struct MinimizedList: Codable, Equatable, Sendable {
    var windows: [MinimizedWindow] = []

    init(_ windows: [MinimizedWindow] = []) {
        self.windows = windows
    }

    var isEmpty: Bool { windows.isEmpty }
    var numbers: Set<Int> { Set(windows.map(\.number)) }

    func contains(_ number: Int) -> Bool {
        windows.contains { $0.number == number }
    }

    /// The window noted as used last in `profile`, if it's on the list.
    func usedLast(in profile: UUID) -> Int? {
        windows.first { $0.profile == profile && $0.usedLast }?.number
    }

    /// Puts a window Side Tabs has just minimized on the list. Marked as used last, it takes the mark from
    /// its profile's other windows.
    mutating func add(_ number: Int, uuid: String?, profile: UUID, usedLast: Bool) {
        windows.removeAll { $0.number == number }
        if usedLast {
            for index in windows.indices where windows[index].profile == profile {
                windows[index].usedLast = false
            }
        }
        windows.append(MinimizedWindow(number: number, uuid: uuid, profile: profile, usedLast: usedLast))
    }

    /// Takes a window off: it came back, or closed.
    mutating func remove(_ number: Int) {
        windows.removeAll { $0.number == number }
    }
}

/// Why windows were minimized or brought back, for the log.
nonisolated enum MinimizeReason: String, Sendable {
    case switched = "a switch"
    case change = "another change of profile"
    case setting = "the setting was turned on"
    case settingOff = "the setting was turned off"
    case start = "Side Tabs started"
    case safariStarted = "Safari started"
    case openedBehind = "another profile's window opened behind"
    case dockIcon = "the Dock icon"
}

/// A window Side Tabs has just minimized or brought back. Until its animation is over, Safari may still
/// report it the way it was.
nonisolated struct WindowInFlight: Equatable, Sendable {
    let minimized: Bool
    let at: Date
}

/// What a change of profile does.
nonisolated struct MinimizePlan: Equatable, Sendable {
    /// Windows to minimize, front to back.
    var minimize: [Int] = []
    /// Of those, the ones to note as used last in their profile.
    var usedLast: Set<Int> = []
    /// Windows to bring back, in order: back to front, ending with the one used last, so they keep their
    /// order behind the front window.
    var restore: [Int] = []

    var isEmpty: Bool { minimize.isEmpty && restore.isEmpty }
}

nonisolated enum MinimizeRules {
    // MARK: - The current profile

    /// The current profile once a window is in front: the window's profile when it's known and the window is
    /// on a desktop being shown. A private window, one whose profile can't be told, or one on a desktop that
    /// isn't shown leaves it as it was, so the profile you were in stays open behind it.
    static func currentProfile(_ current: UUID?, front: ProfileResolution, onShownSpace: Bool) -> UUID? {
        guard onShownSpace, let id = front.profileID else { return current }
        return id
    }

    // MARK: - The list

    /// How long after Side Tabs minimizes or brings back a window Safari may still report it the way it was.
    /// An unknown the live test settles (the animation's length).
    static let animationAllowance: TimeInterval = 1

    /// `windows` as they will be once the animations Side Tabs started are over.
    static func settled(_ windows: [ProfileWindow], inFlight: [Int: WindowInFlight], now: Date) -> [ProfileWindow] {
        windows.map { window in
            guard let flight = inFlight[window.number], now.timeIntervalSince(flight.at) < animationAllowance else { return window }
            var settled = window
            settled.isMinimized = flight.minimized
            return settled
        }
    }

    /// The list after a complete read of Safari's windows: a window that closed comes off it, and so does one
    /// that isn't minimized any more (the user brought it back, or Safari didn't minimize it after all, in
    /// which case the next change minimizes it again).
    static func reconciled(_ list: MinimizedList, with windows: [ProfileWindow]) -> MinimizedList {
        let minimized = Set(windows.filter(\.isMinimized).map(\.number))
        return MinimizedList(list.windows.filter { minimized.contains($0.number) })
    }

    /// The saved list, matched against Safari's windows when Side Tabs starts or Safari has restarted.
    ///
    /// - The same Safari (`sameSafari`, by process ID): window numbers still apply. Windows that closed, or
    ///   that the user brought back meanwhile, drop off.
    /// - After Safari restarted, window numbers are new. When a saved UUID is still a window's, the list is
    ///   matched by UUID. When none is, every minimized window of a profile other than `current` counts as
    ///   Side Tabs': with the setting on nearly all of them are, and the cost is that a window the user
    ///   minimized in another profile comes back once.
    static func matched(_ saved: MinimizedList, sameSafari: Bool, windows: [ProfileWindow], current: UUID?) -> MinimizedList {
        if sameSafari {
            return reconciled(saved, with: windows)
        }
        guard !saved.isEmpty else { return MinimizedList() }
        var list = MinimizedList()
        if uuidsSurvive(saved, windows: windows) {
            for window in windows where window.isMinimized {
                guard let uuid = window.uuid, let entry = saved.windows.first(where: { $0.uuid == uuid }) else { continue }
                list.windows.append(MinimizedWindow(number: window.number, uuid: uuid, profile: window.profile.profileID ?? entry.profile, usedLast: entry.usedLast))
            }
            return list
        }
        guard let current else { return list }
        for window in windows where window.isMinimized {
            guard let profile = window.profile.profileID, profile != current else { continue }
            list.windows.append(MinimizedWindow(number: window.number, uuid: window.uuid, profile: profile))
        }
        return list
    }

    /// Whether any of the saved windows' UUIDs is still a window's: then UUIDs survive a relaunch, and the
    /// list is matched by them.
    static func uuidsSurvive(_ saved: MinimizedList, windows: [ProfileWindow]) -> Bool {
        let savedUUIDs = Set(saved.windows.compactMap(\.uuid))
        return windows.contains { $0.uuid.map(savedUUIDs.contains) ?? false }
    }

    // MARK: - Which windows a change minimizes and brings back

    /// Whether a change of profile would minimize this window: another profile's, open on a desktop being
    /// shown, and not full screen. Never a private window or one whose profile can't be told.
    static func isMinimizable(_ window: ProfileWindow, current: UUID) -> Bool {
        guard let profile = window.profile.profileID, profile != current else { return false }
        return window.isOpenHere && !window.isFullScreen
    }

    /// What a change to profile `current` does. `front` is the window in front (the target of the change),
    /// `left` the profile it changed from, `windows` Safari's windows front to back, and `list` the windows
    /// Side Tabs minimized, already matched and reconciled.
    ///
    /// - **Minimized:** every other profile's window that's open on a desktop being shown, on every display,
    ///   except `front`. Never private or full-screen windows, or windows whose profile can't be told.
    /// - **Used last:** each profile left behind notes its frontmost window, which was in front when it was
    ///   left. Only for `left`, or a profile with no window noted yet: a stray window of a profile left
    ///   earlier (one opened while Side Tabs wasn't running, say) doesn't take the mark.
    /// - **Brought back:** the current profile's windows on the list, except `front`. Back to front, ending
    ///   with the one used last. A window the user minimized isn't on the list, and stays minimized.
    static func plan(current: UUID, left: UUID?, front: Int?, windows: [ProfileWindow], list: MinimizedList) -> MinimizePlan {
        var plan = MinimizePlan()
        var marked = Set<UUID>()
        for window in windows where window.number != front && isMinimizable(window, current: current) {
            plan.minimize.append(window.number)
            guard let profile = window.profile.profileID, !marked.contains(profile) else { continue }
            marked.insert(profile)
            if profile == left || list.usedLast(in: profile) == nil {
                plan.usedLast.insert(window.number)
            }
        }
        let minimized = Set(windows.filter(\.isMinimized).map(\.number))
        let own = list.windows.filter { $0.profile == current && $0.number != front && minimized.contains($0.number) }
        plan.restore = own.reversed().filter { !$0.usedLast }.map(\.number) + own.filter(\.usedLast).map(\.number)
        return plan
    }

    /// Turning the setting off: every window on the list that's still minimized comes back, back to front,
    /// and the list is cleared. Windows the user minimized stay minimized.
    static func restoreAll(_ list: MinimizedList, windows: [ProfileWindow]) -> [Int] {
        let minimized = Set(windows.filter(\.isMinimized).map(\.number))
        return list.windows.reversed().map(\.number).filter(minimized.contains)
    }
}

// MARK: - The Dock icon

/// When the current profile's last window closes, Safari is left with no window of it, and macOS answers a
/// click on Safari's Dock icon by bringing back the window minimized most recently: with the setting on,
/// another profile's. So while the current profile has no open window, a click on the icon that brings back
/// another profile's window within about a second opens a window in the current profile instead (or brings
/// back one the user minimized), and the window macOS brought out goes back into the Dock.
nonisolated enum DockIconRule {
    /// How long after a click on the icon a window of another profile counts as its doing.
    static let clickWindow: TimeInterval = 1
    /// How long to wait for the click after such a window comes to the front, in case the window is
    /// reported first. An unknown the live test settles.
    static let lateClick: TimeInterval = 0.3

    /// Whether to watch for a click on the icon: the setting is on, the current profile is known, and it has
    /// no open window on a desktop being shown. A window the user minimized doesn't count as open: the click
    /// brings that window back itself when it's the one minimized most recently, and otherwise a switch would.
    static func applies(isOn: Bool, current: UUID?, windows: [ProfileWindow]) -> Bool {
        guard isOn, let current else { return false }
        return !windows.contains { $0.profile == .profile(current) && $0.isOpenHere }
    }

    /// Whether a window that has come to the front was brought by a click on the icon: it's another
    /// profile's (never a private window or one whose profile can't be told), and it came within
    /// `clickWindow` of the click, or the click came within `lateClick` after it.
    static func broughtByClick(windowProfile: ProfileResolution, current: UUID?, clickAt: Date?, windowAt: Date) -> Bool {
        guard let current, let clickAt, let profile = windowProfile.profileID, profile != current else { return false }
        let after = windowAt.timeIntervalSince(clickAt)
        return after >= -lateClick && after <= clickWindow
    }
}

// MARK: - Remembering the list

/// The list of windows Side Tabs minimized, beside profiles.json, written whenever it changes. No titles,
/// names or URLs: window numbers, UUIDs and Side Tabs' own profile ids.
///
/// Quitting Side Tabs never brings windows back, and neither does an update, a crash or logging out:
/// turning the setting off is the way. So the list is matched again when Side Tabs starts.
nonisolated struct MinimizedWindowsFile: Codable, Equatable {
    /// The Safari whose window numbers the list has.
    var safariProcessIdentifier: Int32?
    /// The current profile (`SafariProfile.id`).
    var currentProfile: UUID?
    var windows: [MinimizedWindow]

    init(safariProcessIdentifier: Int32?, currentProfile: UUID?, windows: [MinimizedWindow]) {
        self.safariProcessIdentifier = safariProcessIdentifier
        self.currentProfile = currentProfile
        self.windows = windows
    }

    var list: MinimizedList { MinimizedList(windows) }

    static var defaultURL: URL {
        ProfilesFile.defaultURL.deletingLastPathComponent().appending(path: "minimized-windows.json")
    }

    /// The saved list, or nil if there's no file or it can't be read.
    static func load(from url: URL) -> MinimizedWindowsFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MinimizedWindowsFile.self, from: data)
    }

    static func save(_ file: MinimizedWindowsFile, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }
}
