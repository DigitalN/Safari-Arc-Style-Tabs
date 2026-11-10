import Foundation

// Safari's profiles as Side Tabs knows them, and what it keeps of them in profiles.json (#33).
// Kept apart from Accessibility and AppKit so the checks can run them (Tests/ProfileChecks).
//
// Safari tells three things about profiles, each in its own place (#28):
// - File → New Window lists every profile, in Safari's order, by name and whether it's the default.
// - Each window's toolbar has a button that names the window's profile and its SF Symbol.
// - Each profile's copy of the extension sends the profile's UUID (`ProfileKey`).
// Names aren't unique, so a profile is told apart by position, the default flag, its symbol and,
// once known, its key.

/// One Safari profile.
nonisolated struct SafariProfile: Codable, Hashable, Identifiable, Sendable {
    /// Side Tabs' own id for the profile, kept across menu reads and restarts. Safari has no id it
    /// shows before the extension's copy has reported (and none for a profile where it's off).
    var id: UUID
    /// The name as Safari's identifiers carry it. Not unique.
    var name: String
    var isDefault: Bool
    /// The profile's SF Symbol, from a window's toolbar. Nil until a window of it has been seen.
    var symbol: String?
    /// The profile's extension copy, once one has been matched to a window of the profile. Always
    /// `.defaultProfile` for the default profile, whose copy sends no UUID.
    var key: ProfileKey?

    init(id: UUID = UUID(), name: String, isDefault: Bool, symbol: String? = nil, key: ProfileKey? = nil) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.symbol = symbol
        self.key = isDefault ? .defaultProfile : key
    }

    /// What the button shows while the symbol isn't known: the name's first letter.
    var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// One item of File → New Window.
nonisolated struct MenuProfile: Equatable, Sendable {
    var name: String
    var isDefault: Bool
    /// The item has ⌘N, which Safari gives the front window's profile. Only a hint: a recorded
    /// menu (#28) had it on a profile other than the one its window was said to be in front for.
    var hasNewWindowShortcut = false
}

/// What a window's toolbar says about its profile.
nonisolated enum ToolbarProfile: Equatable, Sendable {
    /// `TabGroupPickerButton?Profile=<name>&Icon=<symbol>`.
    case profile(name: String, symbol: String?)
    /// The toolbar has no profile button: a private window (or a toolbar customized without it).
    case noProfileButton
    /// The toolbar couldn't be read (Safari didn't answer, or the window isn't ready yet).
    case unknown
}

// MARK: - Identifiers

nonisolated enum ProfileIdentifiers {
    static let newWindowSubmenuItem = "NewWindowSubmenuItem"
    static let newWindowSubmenu = "NewWindowSubmenu"
    static let fileMenu = "SafariFileMenu"
    static let applicationMenu = "ApplicationMenu"
    static let manageProfilesItem = "ManageProfilesMenuItem"
    static let profileButtonPrefix = "TabGroupPickerButton"
    static let browserWindowPrefix = "SafariWindow"
    static let profilesPane = "SafariProfilesPreferencesView"

    /// `New<name>Window?isDefaultProfile=true|false` → the name and the flag. Nil for anything else.
    /// The name is everything between "New" and the last "Window?isDefaultProfile=", so a name with
    /// "Window", "?", "&" or "=" in it still parses.
    static func menuItem(_ identifier: String?) -> (name: String, isDefault: Bool)? {
        guard let identifier, identifier.hasPrefix("New") else { return nil }
        let marker = "Window?isDefaultProfile="
        guard let range = identifier.range(of: marker, options: .backwards) else { return nil }
        let flag = identifier[range.upperBound...]
        guard flag == "true" || flag == "false" else { return nil }
        let name = identifier[identifier.index(identifier.startIndex, offsetBy: 3)..<range.lowerBound]
        return (decoded(String(name)), flag == "true")
    }

    /// `TabGroupPickerButton?Profile=<name>&Icon=<symbol>` → the name and symbol. The name runs to
    /// the last "&Icon=", since symbol names never contain "&" and a profile name might.
    /// `TabGroupPickerButton?Profile` with no value (what Safari 26 showed in #20's recording)
    /// gives nil: the button is there but names no profile.
    static func toolbarButton(_ identifier: String?) -> (name: String, symbol: String?)? {
        guard let identifier, identifier.hasPrefix(profileButtonPrefix),
              let query = identifier.range(of: "?Profile=") else { return nil }
        let rest = identifier[query.upperBound...]
        if let icon = rest.range(of: "&Icon=", options: .backwards) {
            let symbol = String(rest[icon.upperBound...])
            return (decoded(String(rest[..<icon.lowerBound])), symbol.isEmpty ? nil : decoded(symbol))
        }
        return (decoded(String(rest)), nil)
    }

    static func isProfileButton(_ identifier: String?) -> Bool {
        identifier?.hasPrefix(profileButtonPrefix) == true
    }

    /// Browser windows have `SafariWindow?IsSecure=…&UUID=…`; Settings has `_NS:…`.
    static func isBrowserWindow(_ identifier: String?) -> Bool {
        identifier?.hasPrefix(browserWindowPrefix) == true
    }

    /// The UUID in a browser window's identifier, `SafariWindow?IsSecure=…&UUID=<uuid>`, which may
    /// survive a relaunch (#42). Nil for any other identifier, or an empty UUID. `IsSecure` isn't
    /// whether the window is private: recorded private windows say false.
    static func windowUUID(_ identifier: String?) -> String? {
        guard let identifier, isBrowserWindow(identifier), let query = identifier.firstIndex(of: "?") else { return nil }
        for pair in identifier[identifier.index(after: query)...].split(separator: "&") where pair.hasPrefix("UUID=") {
            let uuid = pair.dropFirst("UUID=".count)
            return uuid.isEmpty ? nil : String(uuid)
        }
        return nil
    }

    /// Nobody has checked yet how Safari writes a name with spaces or symbols into these
    /// identifiers (#28). If it percent-encodes them, decode; otherwise leave the name as it is.
    static func decoded(_ text: String) -> String {
        guard text.contains("%") else { return text }
        return text.removingPercentEncoding ?? text
    }

    /// Whether a name from one identifier is the same as one from another. Equal, or equal without
    /// whitespace, in case one of the two leaves the spaces out.
    static func sameName(_ a: String, _ b: String) -> Bool {
        a == b || a.filter { !$0.isWhitespace } == b.filter { !$0.isWhitespace }
    }

    /// The items of File → New Window, in order, with what they say. Items that aren't a profile's
    /// (none are known) are skipped.
    static func menuProfiles(_ items: [(identifier: String?, commandCharacter: String?, commandModifiers: Int?)]) -> [MenuProfile] {
        items.compactMap { item in
            guard let parsed = menuItem(item.identifier) else { return nil }
            let shortcut = item.commandCharacter?.uppercased() == "N" && (item.commandModifiers ?? 0) == 0
            return MenuProfile(name: parsed.name, isDefault: parsed.isDefault, hasNewWindowShortcut: shortcut)
        }
    }
}

// MARK: - The list of profiles

nonisolated enum ProfileList {
    /// The profiles File → New Window lists, in its order, carrying over what was known about each
    /// one: its id, symbol and key. The menu decides which profiles exist. Matched in this order:
    ///
    /// 1. The default profile is the default profile.
    /// 2. The same name at the same position.
    /// 3. The same name elsewhere: a profile before it was deleted, or the order changed. Profiles
    ///    sharing a name keep their order among themselves.
    /// 4. A different name at the same position, when the menu has as many profiles as before: a
    ///    rename. It keeps its symbol (shown until a window of it says otherwise) but not its key,
    ///    which is learned again, so a guess can't make another profile's copy count as its own.
    ///
    /// The rest are new profiles. Remembered ones left over were deleted.
    static func reconcile(remembered: [SafariProfile], menu: [MenuProfile]) -> [SafariProfile] {
        var result: [SafariProfile?] = Array(repeating: nil, count: menu.count)
        var used = Set<Int>()

        func take(_ menuIndex: Int, _ rememberedIndex: Int, keepKey: Bool = true) {
            var profile = remembered[rememberedIndex]
            // A single-profile menu names no profile; the default keeps the name it had.
            if !menu[menuIndex].name.isEmpty || profile.name.isEmpty {
                profile.name = menu[menuIndex].name
            }
            profile.isDefault = menu[menuIndex].isDefault
            if profile.isDefault {
                profile.key = .defaultProfile
            } else if !keepKey || profile.key == .defaultProfile {
                profile.key = nil
            }
            result[menuIndex] = profile
            used.insert(rememberedIndex)
        }

        // 1. The default.
        if let menuIndex = menu.firstIndex(where: \.isDefault),
           let rememberedIndex = remembered.firstIndex(where: \.isDefault) {
            take(menuIndex, rememberedIndex)
        }
        // 2. Same name, same position.
        for index in menu.indices where result[index] == nil && !menu[index].isDefault {
            guard remembered.indices.contains(index), !used.contains(index), !remembered[index].isDefault,
                  ProfileIdentifiers.sameName(remembered[index].name, menu[index].name) else { continue }
            take(index, index)
        }
        // 3. Same name elsewhere, in order.
        for index in menu.indices where result[index] == nil && !menu[index].isDefault {
            guard let rememberedIndex = remembered.indices.first(where: {
                !used.contains($0) && !remembered[$0].isDefault && ProfileIdentifiers.sameName(remembered[$0].name, menu[index].name)
            }) else { continue }
            take(index, rememberedIndex)
        }
        // 4. Renamed in place.
        if menu.count == remembered.count {
            for index in menu.indices where result[index] == nil && !menu[index].isDefault {
                guard !used.contains(index), !remembered[index].isDefault else { continue }
                take(index, index, keepKey: false)
            }
        }
        return menu.indices.map { index in
            result[index] ?? SafariProfile(name: menu[index].name, isDefault: menu[index].isDefault)
        }
    }

    /// Gives `key` to the profile with `id`, and takes it from any other profile that had it (it
    /// was a guess that turned out wrong). The default profile's key never moves.
    static func assign(_ key: ProfileKey, to id: UUID, in profiles: inout [SafariProfile]) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        guard profiles[index].isDefault == key.isDefault, profiles[index].key != key else { return false }
        for other in profiles.indices where other != index && profiles[other].key == key {
            profiles[other].key = nil
        }
        profiles[index].key = key
        return true
    }
}

// MARK: - Checking a read against what else is known (#40)

/// What else says which profiles exist, to check a read of the menu against.
nonisolated struct ProfileEvidence: Equatable, Sendable {
    /// What the open windows' toolbars say.
    var toolbars: [ToolbarProfile] = []
    /// The profiles of the extension copies sending heartbeats.
    var liveKeys: Set<ProfileKey> = []
}

/// The list after a read of the menu, and how the read compared with the evidence.
nonisolated struct ProfileListUpdate: Equatable {
    var profiles: [SafariProfile]
    /// When each profile the read lacked, and nothing else showed, was first missed.
    var missingSince: [UUID: Date] = [:]
    /// The read lacked them, but an open window shows them: kept.
    var keptForWindows: [UUID] = []
    /// The read lacked them, but their extension copy is live: kept.
    var keptForCopies: [UUID] = []
    /// Open windows show them, and neither the read nor the list had them: added.
    var addedFromWindows: [UUID] = []
    /// The read lacked them and nothing else shows them: kept until a second read agrees.
    var awaitingSecondRead: [UUID] = []
    /// Gone: two reads agree, and nothing else shows them.
    var removed: [UUID] = []

    /// The read agrees with everything else known; otherwise it's read again.
    var agrees: Bool {
        keptForWindows.isEmpty && keptForCopies.isEmpty && addedFromWindows.isEmpty && awaitingSecondRead.isEmpty
    }
}

extension ProfileList {
    /// How long after the first read that lacked a profile a second one has to be, to agree it's gone.
    static let secondReadAfter: TimeInterval = 0.8

    /// The list after a read of the menu (`menu`), checked against open windows and live extension
    /// copies. The bar never loses a profile because of one read:
    ///
    /// - A profile the read has, or a new one it lists, is taken as the menu says (`reconcile`).
    /// - A profile the read lacks that an open window's toolbar or a live copy still shows is kept, in
    ///   its place, with its symbol and key: the read came up short.
    /// - A profile windows show that neither the read nor the list has is added at the end, from what
    ///   its toolbar says. That repairs a profiles.json left with too few profiles.
    /// - A profile the read lacks that nothing else shows goes only when a read at least
    ///   `secondReadAfter` after the first that lacked it agrees (`missingSince`), and `mayDrop` (not
    ///   while Safari or Side Tabs is starting). Until then it's kept.
    static func update(_ remembered: [SafariProfile], read menu: [MenuProfile], evidence: ProfileEvidence,
                       missingSince: [UUID: Date], now: Date, mayDrop: Bool) -> ProfileListUpdate {
        var profiles = reconcile(remembered: remembered, menu: menu)
        var update = ProfileListUpdate(profiles: [])

        // A window shows a profile when its toolbar names it, with the same symbol once both are known.
        func shows(_ name: String, _ symbol: String?, _ profile: SafariProfile) -> Bool {
            ProfileIdentifiers.sameName(name, profile.name) && (symbol == nil || profile.symbol == nil || symbol == profile.symbol)
        }
        var windowsShow = Set<UUID>()
        var unknown: [(name: String, symbol: String?)] = []
        for toolbar in evidence.toolbars {
            guard case .profile(let name, let symbol) = toolbar, !name.isEmpty,
                  !profiles.contains(where: { shows(name, symbol, $0) }) else { continue }
            let before = remembered.filter { shows(name, symbol, $0) }
            if before.isEmpty {
                if !unknown.contains(where: { ProfileIdentifiers.sameName($0.name, name) && $0.symbol == symbol }) {
                    unknown.append((name, symbol))
                }
            } else {
                before.forEach { windowsShow.insert($0.id) }
            }
        }

        let readIDs = Set(profiles.map(\.id))
        for (index, profile) in remembered.enumerated() where !readIDs.contains(profile.id) {
            let keep: Bool
            if windowsShow.contains(profile.id) {
                update.keptForWindows.append(profile.id)
                keep = true
            } else if let key = profile.key, evidence.liveKeys.contains(key) {
                update.keptForCopies.append(profile.id)
                keep = true
            } else if mayDrop, let since = missingSince[profile.id], now.timeIntervalSince(since) >= secondReadAfter {
                update.removed.append(profile.id)
                keep = false
            } else {
                update.awaitingSecondRead.append(profile.id)
                update.missingSince[profile.id] = missingSince[profile.id] ?? now
                keep = true
            }
            guard keep else { continue }
            // Back in its place: after the nearest profile before it that's still listed.
            let previous = remembered[..<index].last { candidate in profiles.contains { $0.id == candidate.id } }
            let at = previous.flatMap { candidate in profiles.firstIndex { $0.id == candidate.id } }.map { $0 + 1 } ?? 0
            profiles.insert(profile, at: at)
        }
        for found in unknown {
            let profile = SafariProfile(name: found.name, isDefault: false, symbol: found.symbol)
            update.addedFromWindows.append(profile.id)
            profiles.append(profile)
        }
        update.profiles = profiles
        return update
    }
}

// MARK: - profiles.json

/// What Side Tabs remembers about Safari's profiles, beside state.json, so the bottom bar is right
/// at launch, and icons show for profiles with no windows open.
nonisolated struct ProfilesFile: Codable, Equatable {
    /// In Safari's order.
    var profiles: [SafariProfile]

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Side Tabs", directoryHint: .isDirectory).appending(path: "profiles.json")
    }

    /// The saved profiles, or none if there's no file or it can't be read.
    static func load(from url: URL) -> [SafariProfile] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ProfilesFile.self, from: data) else { return [] }
        return file.profiles
    }

    static func save(_ profiles: [SafariProfile], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ProfilesFile(profiles: profiles)).write(to: url, options: .atomic)
    }
}
