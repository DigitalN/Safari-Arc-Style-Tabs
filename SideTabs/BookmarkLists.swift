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
/// across all of them, so #25's links (keyed by bookmark id) serve every list. Each Pinned list is a tree of
/// pinned items and folders (#76, PinnedTree.swift); folder ids are unique too, and never a bookmark's.
struct BookmarkLists: Equatable {
    /// Only profiles with something in a list have an entry there. A profile deleted in Safari keeps its
    /// lists, which is harmless: nothing shows them.
    private(set) var favorites: [ProfileKey: [Bookmark]] = [:]
    /// Each profile's Pinned tree. A profile whose list holds only empty folders keeps its entry.
    private(set) var pinned: [ProfileKey: [PinnedNode]] = [:]

    init() {}

    /// The lists as state.json keeps them, by `ProfileKey.rawValue`. `favorites` is nil in a file saved
    /// before favorites belonged to profiles (#38), or by a version that doesn't know the key and dropped it:
    /// then `bookmarks`, which held the bookmarks before there were profiles' lists, becomes the default
    /// profile's favorites. Likewise `pinnedTree` (#76) is nil in a file saved before there were folders, or by
    /// a version without them: then each Pinned list is the flat `pinned` one, with no folders. An id that turns
    /// up twice is given a new one, so ids stay unique.
    init(favorites: [String: [Bookmark]]?, bookmarks: [Bookmark], pinned: [String: [Bookmark]], pinnedTree: [String: [PinnedNode]]? = nil) {
        var seen = Set<UUID>()
        func unique(_ bookmark: Bookmark) -> Bookmark {
            var bookmark = bookmark
            while !seen.insert(bookmark.id).inserted {
                bookmark.id = UUID()
            }
            return bookmark
        }
        func unique(_ nodes: [PinnedNode]) -> [PinnedNode] {
            nodes.map { node in
                switch node {
                case .bookmark(let bookmark):
                    return .bookmark(unique(bookmark))
                case .folder(var folder):
                    while !seen.insert(folder.id).inserted {
                        folder.id = UUID()
                    }
                    folder.children = unique(folder.children)
                    return .folder(folder)
                }
            }
        }
        // In a fixed order, the default profile's first, so which copy keeps a repeated id doesn't change
        // from launch to launch.
        func ordered<List>(_ lists: [String: [List]]) -> [(key: String, value: [List])] {
            let rank = { (key: String) in key == ProfileKey.defaultProfile.rawValue ? 0 : 1 }
            return lists.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
        }
        for (profile, list) in ordered(favorites ?? [ProfileKey.defaultProfile.rawValue: bookmarks]) where !list.isEmpty {
            self.favorites[ProfileKey(rawValue: profile)] = list.map(unique)
        }
        let trees = pinnedTree ?? pinned.mapValues { $0.map(PinnedNode.bookmark) }
        for (profile, tree) in ordered(trees) where !tree.isEmpty {
            self.pinned[ProfileKey(rawValue: profile)] = unique(tree)
        }
    }

    /// The favorites keyed the way state.json keeps them.
    var savedFavorites: [String: [Bookmark]] {
        Dictionary(uniqueKeysWithValues: favorites.map { ($0.key.rawValue, $0.value) })
    }

    /// The Pinned lists keyed the way state.json's flat `pinned` key keeps them: every pinned item, at any depth,
    /// in display order, and no folders. Versions without folders read this.
    var savedPinned: [String: [Bookmark]] {
        Dictionary(uniqueKeysWithValues: pinned.compactMap { profile, tree in
            let items = tree.flattenedBookmarks
            return items.isEmpty ? nil : (profile.rawValue, items)
        })
    }

    /// The Pinned trees keyed the way state.json keeps them (#76).
    var savedPinnedTree: [String: [PinnedNode]] {
        Dictionary(uniqueKeysWithValues: pinned.map { ($0.key.rawValue, $0.value) })
    }

    // MARK: Reading

    /// The list's bookmarks in display order. For a Pinned list that's every pinned item, at any depth,
    /// inside folders open or closed.
    func items(in list: BookmarkList) -> [Bookmark] {
        switch list {
        case .favorites(let profile): favorites[profile] ?? []
        case .pinned(let profile): pinnedTree(of: profile).flattenedBookmarks
        }
    }

    /// A profile's Pinned list, folders and all.
    func pinnedTree(of profile: ProfileKey) -> [PinnedNode] {
        pinned[profile] ?? []
    }

    /// Every bookmark in every list.
    var all: [Bookmark] {
        Array(favorites.values.joined()) + pinned.values.flatMap(\.flattenedBookmarks)
    }

    func bookmark(_ id: UUID) -> Bookmark? {
        all.first { $0.id == id }
    }

    func list(containing id: UUID) -> BookmarkList? {
        if let profile = favorites.first(where: { $0.value.contains { $0.id == id } })?.key {
            return .favorites(profile)
        }
        return pinned.first { $0.value.flattenedBookmarks.contains { $0.id == id } }.map { .pinned($0.key) }
    }

    /// The folder, and the profile whose Pinned list it's in.
    func folder(_ id: UUID) -> (folder: PinnedFolder, profile: ProfileKey)? {
        for (profile, tree) in pinned {
            if let folder = tree.folder(id) { return (folder, profile) }
        }
        return nil
    }

    /// The profile whose Pinned list holds the node (a pinned item or a folder), and its place there.
    func pinnedPlace(of id: UUID) -> (profile: ProfileKey, place: PinnedPlace)? {
        for (profile, tree) in pinned {
            if let place = tree.place(of: id) { return (profile, place) }
        }
        return nil
    }

    /// Where a bookmark is: its list, and its place there (a favorite's is its index at the top level).
    struct Location: Equatable {
        let list: BookmarkList
        let place: PinnedPlace
    }

    func location(of id: UUID) -> Location? {
        if let (profile, place) = pinnedPlace(of: id) {
            return Location(list: .pinned(profile), place: place)
        }
        guard let list = list(containing: id), let index = items(in: list).firstIndex(where: { $0.id == id }) else { return nil }
        return Location(list: list, place: PinnedPlace(parent: nil, index: index))
    }

    /// What a window shows: its profile's favorites, then its Pinned list, at every depth (#76): an item in a
    /// collapsed folder keeps its tab. `profile` is nil for a private window, which shows neither.
    func shown(in profile: ProfileKey?) -> [Bookmark] {
        guard let profile else { return [] }
        return items(in: .favorites(profile)) + items(in: .pinned(profile))
    }

    /// Whether the id is a bookmark's or a folder's anywhere.
    private func isTaken(_ id: UUID) -> Bool {
        bookmark(id) != nil || pinned.values.contains { $0.contains(id: id) }
    }

    // MARK: Changes

    /// Puts a new bookmark at `index` in `list` (at the end without one). In a Pinned list that's its top
    /// level. A bookmark whose id is already in a list isn't added again.
    mutating func insert(_ bookmark: Bookmark, into list: BookmarkList, at index: Int? = nil) {
        switch list {
        case .favorites(let profile):
            guard !isTaken(bookmark.id) else { return }
            var items = favorites[profile] ?? []
            items.insert(bookmark, at: index.map { min(max($0, 0), items.count) } ?? items.count)
            favorites[profile] = items
        case .pinned(let profile):
            insert(.bookmark(bookmark), intoPinnedOf: profile, at: PinnedPlace(parent: nil, index: index ?? .max))
        }
    }

    /// Puts a new pinned item or folder at `place` in the profile's Pinned list. Refused (returns false) when an id
    /// in it is already taken, or the folder it's to go in isn't in that list.
    @discardableResult
    mutating func insert(_ node: PinnedNode, intoPinnedOf profile: ProfileKey, at place: PinnedPlace) -> Bool {
        guard ![node].allIds.contains(where: isTaken) else { return false }
        var tree = pinnedTree(of: profile)
        guard tree.insert(node, at: place) else { return false }
        pinned[profile] = tree
        return true
    }

    /// Puts a bookmark back where `location(of:)` said it was, or at the end of its list's top level if the
    /// folder it was in has gone since.
    mutating func insert(_ bookmark: Bookmark, at location: Location) {
        switch location.list {
        case .favorites:
            insert(bookmark, into: location.list, at: location.place.index)
        case .pinned(let profile):
            if !insert(.bookmark(bookmark), intoPinnedOf: profile, at: location.place) {
                insert(.bookmark(bookmark), intoPinnedOf: profile, at: .end(of: nil))
            }
        }
    }

    /// Takes the bookmark out of whichever list holds it, at any depth.
    @discardableResult
    mutating func remove(_ id: UUID) -> Bookmark? {
        guard let list = list(containing: id) else { return nil }
        switch list {
        case .favorites(let profile):
            var items = favorites[profile] ?? []
            guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            let removed = items.remove(at: index)
            favorites[profile] = items.isEmpty ? nil : items
            return removed
        case .pinned(let profile):
            var tree = pinnedTree(of: profile)
            guard case .bookmark(let removed)? = tree.remove(id: id) else { return nil }
            pinned[profile] = tree.isEmpty ? nil : tree
            return removed
        }
    }

    /// Takes the folder out of its Pinned list, with everything inside it, and returns the pinned items it held,
    /// at any depth. Nil when there's no such folder.
    mutating func removeFolder(_ id: UUID) -> [Bookmark]? {
        guard let (_, profile) = folder(id) else { return nil }
        var tree = pinnedTree(of: profile)
        guard case .folder(let removed)? = tree.remove(id: id) else { return nil }
        pinned[profile] = tree.isEmpty ? nil : tree
        return removed.children.flattenedBookmarks
    }

    /// Moves the bookmark to `index` in `list` (its position once moved), from the same list or
    /// another. In a Pinned list that's its top level. Says whether it was found.
    @discardableResult
    mutating func move(_ id: UUID, to list: BookmarkList, at index: Int) -> Bool {
        switch list {
        case .favorites:
            guard let bookmark = remove(id) else { return false }
            insert(bookmark, into: list, at: index)
            return true
        case .pinned(let profile):
            return movePinned(id, in: profile, to: PinnedPlace(parent: nil, index: index))
        }
    }

    /// Moves a bookmark (from any list) or a folder to `place` in the profile's Pinned list, given as it would be
    /// with the node already taken out (its position once moved). Refused when the place is in another profile's
    /// list, or inside the folder being moved. Says whether it moved.
    @discardableResult
    mutating func movePinned(_ id: UUID, in profile: ProfileKey, to place: PinnedPlace) -> Bool {
        if let parent = place.parent, pinnedPlace(of: parent)?.profile != profile { return false }
        if let (from, _) = pinnedPlace(of: id) {
            // Within one Pinned list (a list never crosses profiles, see TabStore.moveBookmark).
            guard from == profile else { return false }
            var tree = pinnedTree(of: profile)
            guard tree.move(id: id, to: place) else { return false }
            pinned[profile] = tree
            return true
        }
        // A favorite going into Pinned.
        guard let bookmark = favorites.values.joined().first(where: { $0.id == id }) else { return false }
        var tree = pinnedTree(of: profile)
        guard tree.insert(.bookmark(bookmark), at: place) else { return false }
        remove(id)
        pinned[profile] = tree
        return true
    }

    /// Changes the bookmark wherever it is (a rename, Replace with Current Page). The id stays.
    mutating func update(_ id: UUID, _ body: (inout Bookmark) -> Void) {
        guard let list = list(containing: id) else { return }
        switch list {
        case .favorites(let profile):
            guard var items = favorites[profile], let index = items.firstIndex(where: { $0.id == id }) else { return }
            body(&items[index])
            items[index].id = id
            favorites[profile] = items
        case .pinned(let profile):
            var tree = pinnedTree(of: profile)
            tree.updateBookmark(id, body)
            pinned[profile] = tree
        }
    }

    /// Changes a folder's name or whether it's open, wherever it is.
    mutating func updateFolder(_ id: UUID, _ body: (inout PinnedFolder) -> Void) {
        guard let (_, profile) = folder(id) else { return }
        var tree = pinnedTree(of: profile)
        tree.updateFolder(id, body)
        pinned[profile] = tree
    }
}
