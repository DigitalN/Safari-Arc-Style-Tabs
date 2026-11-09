import Foundation

// Favorites and the Pinned lists (#34, #38). Each space is a Safari profile, and each profile has its own
// Favorites (the grid at the top of the sidebar) and its own Pinned list. Private windows belong to no
// profile and have neither. Both hold bookmarks with #25's rules (BookmarkTabs.swift): opening one gives
// it a tab of its own in that window. The rules are kept here, apart from SwiftUI and Safari, so
// Tests/StoreChecks can check them; TabStore keeps one of these and saves it in state.json.

/// Which list a bookmark is in: one profile's Favorites or Pinned list.
nonisolated enum BookmarkList: Hashable, Sendable, CustomStringConvertible {
    case favorites(ProfileKey)
    case pinned(ProfileKey)

    /// The profile the list belongs to.
    var profile: ProfileKey {
        switch self {
        case .favorites(let profile), .pinned(let profile): profile
        }
    }

    /// For the log: never a profile's name, which the log doesn't get. A profile's UUID is shortened.
    var description: String {
        let owner = profile.isDefault ? "the default profile's" : "profile \(profile.rawValue.prefix(8))'s"
        switch self {
        case .favorites: return "\(owner) Favorites"
        case .pinned: return "\(owner) Pinned"
        }
    }
}

/// Every profile's Favorites and Pinned list. A bookmark is in exactly one list, and its id is unique
/// across all of them, so #25's links (keyed by bookmark id) serve every list.
struct BookmarkLists: Equatable {
    /// Only profiles with something in a list have an entry there. A profile deleted in Safari keeps its
    /// lists, which is harmless: nothing shows them.
    private(set) var favorites: [ProfileKey: [Bookmark]] = [:]
    private(set) var pinned: [ProfileKey: [Bookmark]] = [:]

    init() {}

    /// The lists as state.json keeps them, by `ProfileKey.rawValue`. `favorites` is nil in a file saved
    /// before favorites belonged to profiles (#38), or by a version that doesn't know the key and dropped it:
    /// then `bookmarks`, which held the bookmarks before there were profiles' lists, becomes the default
    /// profile's favorites. An id that turns up twice is given a new one, so ids stay unique.
    init(favorites: [String: [Bookmark]]?, bookmarks: [Bookmark], pinned: [String: [Bookmark]]) {
        var seen = Set<UUID>()
        func unique(_ list: [Bookmark]) -> [Bookmark] {
            list.map { bookmark in
                var bookmark = bookmark
                while !seen.insert(bookmark.id).inserted {
                    bookmark.id = UUID()
                }
                return bookmark
            }
        }
        // In a fixed order, the default profile's first, so which copy keeps a repeated id doesn't change
        // from launch to launch.
        func ordered(_ lists: [String: [Bookmark]]) -> [(key: String, value: [Bookmark])] {
            let rank = { (key: String) in key == ProfileKey.defaultProfile.rawValue ? 0 : 1 }
            return lists.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
        }
        for (profile, list) in ordered(favorites ?? [ProfileKey.defaultProfile.rawValue: bookmarks]) where !list.isEmpty {
            self.favorites[ProfileKey(rawValue: profile)] = unique(list)
        }
        for (profile, list) in ordered(pinned) where !list.isEmpty {
            self.pinned[ProfileKey(rawValue: profile)] = unique(list)
        }
    }

    /// The favorites keyed the way state.json keeps them.
    var savedFavorites: [String: [Bookmark]] {
        Dictionary(uniqueKeysWithValues: favorites.map { ($0.key.rawValue, $0.value) })
    }

    /// The Pinned lists keyed the way state.json keeps them.
    var savedPinned: [String: [Bookmark]] {
        Dictionary(uniqueKeysWithValues: pinned.map { ($0.key.rawValue, $0.value) })
    }

    // MARK: Reading

    func items(in list: BookmarkList) -> [Bookmark] {
        switch list {
        case .favorites(let profile): favorites[profile] ?? []
        case .pinned(let profile): pinned[profile] ?? []
        }
    }

    /// Every bookmark in every list.
    var all: [Bookmark] {
        Array(favorites.values.joined()) + pinned.values.joined()
    }

    func bookmark(_ id: UUID) -> Bookmark? {
        all.first { $0.id == id }
    }

    func list(containing id: UUID) -> BookmarkList? {
        if let profile = favorites.first(where: { $0.value.contains { $0.id == id } })?.key {
            return .favorites(profile)
        }
        return pinned.first { $0.value.contains { $0.id == id } }.map { .pinned($0.key) }
    }

    /// What a window shows: its profile's favorites, then its Pinned list. `profile` is nil for a private
    /// window, which shows neither.
    func shown(in profile: ProfileKey?) -> [Bookmark] {
        guard let profile else { return [] }
        return items(in: .favorites(profile)) + items(in: .pinned(profile))
    }

    // MARK: Changes

    /// Puts a new bookmark at `index` in `list` (at the end without one). A bookmark whose id is
    /// already in a list isn't added again.
    mutating func insert(_ bookmark: Bookmark, into list: BookmarkList, at index: Int? = nil) {
        guard self.bookmark(bookmark.id) == nil else { return }
        change(list) { items in
            let position = index.map { min(max($0, 0), items.count) } ?? items.count
            items.insert(bookmark, at: position)
        }
    }

    /// Takes the bookmark out of whichever list holds it.
    @discardableResult
    mutating func remove(_ id: UUID) -> Bookmark? {
        guard let list = list(containing: id) else { return nil }
        var removed: Bookmark?
        change(list) { items in
            if let index = items.firstIndex(where: { $0.id == id }) {
                removed = items.remove(at: index)
            }
        }
        return removed
    }

    /// Moves the bookmark to `index` in `list` (its position once moved), from the same list or
    /// another. Says whether it was found.
    @discardableResult
    mutating func move(_ id: UUID, to list: BookmarkList, at index: Int) -> Bool {
        guard let bookmark = remove(id) else { return false }
        change(list) { items in
            items.insert(bookmark, at: min(max(index, 0), items.count))
        }
        return true
    }

    /// Changes the bookmark wherever it is (a rename, Replace with Current Page). The id stays.
    mutating func update(_ id: UUID, _ body: (inout Bookmark) -> Void) {
        guard let list = list(containing: id) else { return }
        change(list) { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            body(&items[index])
            items[index].id = id
        }
    }

    private mutating func change(_ list: BookmarkList, _ body: (inout [Bookmark]) -> Void) {
        switch list {
        case .favorites(let profile):
            Self.change(&favorites, profile, body)
        case .pinned(let profile):
            Self.change(&pinned, profile, body)
        }
    }

    private static func change(_ lists: inout [ProfileKey: [Bookmark]], _ profile: ProfileKey, _ body: (inout [Bookmark]) -> Void) {
        var items = lists[profile] ?? []
        body(&items)
        lists[profile] = items.isEmpty ? nil : items
    }
}
