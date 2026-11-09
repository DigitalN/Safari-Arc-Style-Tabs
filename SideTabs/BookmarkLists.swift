import Foundation

// Favorites and the Pinned lists (#34). Each space is a Safari profile, and each profile has a Pinned
// list of its own. Favorites, the grid at the top of the sidebar, are shared by every profile and
// show in private windows too. Both hold bookmarks with #25's rules (BookmarkTabs.swift): opening one
// gives it a tab of its own in that window. The rules are kept here, apart from SwiftUI and Safari, so
// Tests/StoreChecks can check them; TabStore keeps one of these and saves it in state.json.

/// Which list a bookmark is in.
nonisolated enum BookmarkList: Hashable, Sendable, CustomStringConvertible {
    /// Shared by every profile, and shown in private windows too.
    case favorites
    /// One profile's own list. Private windows belong to no profile and have none.
    case pinned(ProfileKey)

    /// For the log: never a profile's name, which the log doesn't get. A profile's UUID is shortened.
    var description: String {
        switch self {
        case .favorites: "Favorites"
        case .pinned(let profile) where profile.isDefault: "the default profile's Pinned"
        case .pinned(let profile): "profile \(profile.rawValue.prefix(8))'s Pinned"
        }
    }
}

/// The favorites and every profile's Pinned list. A bookmark is in exactly one list, and its id is
/// unique across all of them, so #25's links (keyed by bookmark id) serve both.
struct BookmarkLists: Equatable {
    private(set) var favorites: [Bookmark] = []
    /// Only profiles with something pinned have an entry. A profile deleted in Safari keeps its list,
    /// which is harmless: nothing shows it.
    private(set) var pinned: [ProfileKey: [Bookmark]] = [:]

    init() {}

    /// The lists as state.json keeps them: `bookmarks` holds the favorites (as it held every bookmark
    /// before there were Pinned lists, so an older file needs no converting), and `pinned` the Pinned
    /// lists by `ProfileKey.rawValue`. An id that turns up twice is given a new one, so ids stay unique.
    init(favorites: [Bookmark], pinned: [String: [Bookmark]]) {
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
        self.favorites = unique(favorites)
        // In a fixed order, so which copy keeps a repeated id doesn't change from launch to launch.
        for (profile, list) in pinned.sorted(by: { $0.key < $1.key }) where !list.isEmpty {
            self.pinned[ProfileKey(rawValue: profile)] = unique(list)
        }
    }

    /// The Pinned lists keyed the way state.json keeps them.
    var savedPinned: [String: [Bookmark]] {
        Dictionary(uniqueKeysWithValues: pinned.map { ($0.key.rawValue, $0.value) })
    }

    // MARK: Reading

    func items(in list: BookmarkList) -> [Bookmark] {
        switch list {
        case .favorites: favorites
        case .pinned(let profile): pinned[profile] ?? []
        }
    }

    /// Every bookmark in every list.
    var all: [Bookmark] {
        favorites + pinned.values.joined()
    }

    var allIds: Set<UUID> { Set(all.map(\.id)) }

    func bookmark(_ id: UUID) -> Bookmark? {
        favorites.first { $0.id == id } ?? pinned.values.lazy.compactMap { $0.first { $0.id == id } }.first
    }

    func list(containing id: UUID) -> BookmarkList? {
        if favorites.contains(where: { $0.id == id }) {
            return .favorites
        }
        return pinned.first { $0.value.contains { $0.id == id } }.map { .pinned($0.key) }
    }

    /// What a window shows: the favorites, then its profile's Pinned list. `profile` is nil for a
    /// private window, which shows only the favorites.
    func shown(in profile: ProfileKey?) -> [Bookmark] {
        favorites + (profile.flatMap { pinned[$0] } ?? [])
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
        case .favorites:
            body(&favorites)
        case .pinned(let profile):
            var items = pinned[profile] ?? []
            body(&items)
            pinned[profile] = items.isEmpty ? nil : items
        }
    }
}
