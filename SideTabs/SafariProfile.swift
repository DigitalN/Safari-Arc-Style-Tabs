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
            profile.name = menu[menuIndex].name
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
