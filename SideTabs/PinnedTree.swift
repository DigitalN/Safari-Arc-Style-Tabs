import CoreGraphics
import Foundation

// Folders in each profile's Pinned list (#76). A profile's Pinned list is a tree: pinned items and folders mixed in
// any order, and folders holding more of both, with no depth limit. Pinned items keep #25's rules wherever they are
// (BookmarkTabs.swift). `PinnedOutline` is the list of rows the sidebar draws from a tree, and where a drop on it
// lands. The rules are kept here, apart from SwiftUI and Safari, so Tests/StoreChecks can check them; BookmarkLists
// keeps the trees and TabStore saves them in state.json.

/// A folder in a profile's Pinned list.
struct PinnedFolder: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Whether it shows what's inside. Saved, so it survives restarts.
    var isOpen: Bool
    var children: [PinnedNode]

    private enum CodingKeys: String, CodingKey {
        case id, name, isOpen = "open", children
    }
}

/// An entry in a Pinned list: a pinned item or a folder.
enum PinnedNode: Equatable, Identifiable {
    case bookmark(Bookmark)
    case folder(PinnedFolder)

    var id: UUID {
        switch self {
        case .bookmark(let bookmark): bookmark.id
        case .folder(let folder): folder.id
        }
    }
}

/// state.json keeps a node as `{"bookmark": {…}}` or `{"folder": {…}}`.
extension PinnedNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case bookmark, folder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let folder = try container.decodeIfPresent(PinnedFolder.self, forKey: .folder) {
            self = .folder(folder)
        } else {
            self = .bookmark(try container.decode(Bookmark.self, forKey: .bookmark))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bookmark(let bookmark): try container.encode(bookmark, forKey: .bookmark)
        case .folder(let folder): try container.encode(folder, forKey: .folder)
        }
    }
}

/// A place in a Pinned tree: inside `parent` (nil for the top level), at `index` among its children. An index past
/// the end is the end.
struct PinnedPlace: Equatable, CustomStringConvertible {
    var parent: UUID?
    var index: Int

    static func end(of parent: UUID?) -> PinnedPlace { PinnedPlace(parent: parent, index: .max) }

    /// For the log: never a folder's name.
    var description: String {
        "\(parent == nil ? "the top level" : "a folder") at \(index == .max ? "the end" : "\(index)")"
    }
}

/// A profile's Pinned list as a tree, and what can be done to it. Everything here keeps the ids in a tree unique, and
/// never puts a folder inside itself.
extension Array where Element == PinnedNode {
    /// The pinned items in display order: depth-first, inside folders open or closed. That's the order state.json's
    /// flat `pinned` key keeps them in, for versions without folders.
    var flattenedBookmarks: [Bookmark] {
        flatMap { node -> [Bookmark] in
            switch node {
            case .bookmark(let bookmark): [bookmark]
            case .folder(let folder): folder.children.flattenedBookmarks
            }
        }
    }

    /// Every folder, at any depth, each before those inside it.
    var allFolders: [PinnedFolder] {
        flatMap { node -> [PinnedFolder] in
            guard case .folder(let folder) = node else { return [] }
            return [folder] + folder.children.allFolders
        }
    }

    /// Every id in the tree, at any depth.
    var allIds: [UUID] {
        flatMap { node -> [UUID] in
            switch node {
            case .bookmark(let bookmark): [bookmark.id]
            case .folder(let folder): [folder.id] + folder.children.allIds
            }
        }
    }

    func contains(id: UUID) -> Bool { path(of: id) != nil }

    /// The indexes leading to the node: its index at the top level, then in each folder down to it.
    func path(of id: UUID) -> [Int]? {
        for (index, node) in enumerated() {
            if node.id == id { return [index] }
            if case .folder(let folder) = node, let inner = folder.children.path(of: id) {
                return [index] + inner
            }
        }
        return nil
    }

    func node(_ id: UUID) -> PinnedNode? {
        path(of: id).map(node(at:))
    }

    func folder(_ id: UUID) -> PinnedFolder? {
        if case .folder(let folder)? = node(id) { return folder }
        return nil
    }

    /// The node's place: the folder it's in and its index there.
    func place(of id: UUID) -> PinnedPlace? {
        guard let path = path(of: id) else { return nil }
        return PinnedPlace(parent: parentId(of: path), index: path[path.count - 1])
    }

    /// The folders the node is in, outermost first.
    func ancestors(of id: UUID) -> [UUID] {
        guard let path = path(of: id) else { return [] }
        return (1..<path.count).map { node(at: [Int](path.prefix($0))).id }
    }

    private func parentId(of path: [Int]) -> UUID? {
        path.count > 1 ? node(at: [Int](path.dropLast())).id : nil
    }

    private func node(at path: [Int]) -> PinnedNode {
        let node = self[path[0]]
        guard path.count > 1, case .folder(let folder) = node else { return node }
        return folder.children.node(at: [Int](path.dropFirst()))
    }

    /// Takes the node out, with everything inside it.
    @discardableResult
    mutating func remove(id: UUID) -> PinnedNode? {
        guard let path = path(of: id) else { return nil }
        return remove(at: path)
    }

    private mutating func remove(at path: [Int]) -> PinnedNode {
        if path.count == 1 {
            return remove(at: path[0])
        }
        guard case .folder(var folder) = self[path[0]] else { preconditionFailure("a path only goes through folders") }
        let removed = folder.children.remove(at: [Int](path.dropFirst()))
        self[path[0]] = .folder(folder)
        return removed
    }

    /// Puts the node at `place`. Refused (returns false) when its folder isn't in the tree, or when an id in the node
    /// is already in the tree.
    @discardableResult
    mutating func insert(_ node: PinnedNode, at place: PinnedPlace) -> Bool {
        let ids = Set(allIds)
        let incoming = [node].allIds
        guard Set(incoming).count == incoming.count, ids.isDisjoint(with: incoming) else { return false }
        guard let parent = place.parent else {
            insert(node, at: Self.clamped(place.index, count))
            return true
        }
        return changeFolder(parent) { folder in
            folder.children.insert(node, at: Self.clamped(place.index, folder.children.count))
        }
    }

    /// Moves the node to `place`, given as it would be with the node already taken out (its position once moved).
    /// A folder can't go into itself or a folder inside it: that's refused, and so is a node or folder that isn't
    /// in the tree. Says whether it moved.
    @discardableResult
    mutating func move(id: UUID, to place: PinnedPlace) -> Bool {
        if let parent = place.parent, parent == id || ancestors(of: parent).contains(id) { return false }
        var moved = self
        guard let node = moved.remove(id: id), moved.insert(node, at: place) else { return false }
        self = moved
        return true
    }

    /// Changes the folder wherever it is. Its id and children stay; `body` changes its name or whether it's open.
    /// Says whether it was found.
    @discardableResult
    mutating func updateFolder(_ id: UUID, _ body: (inout PinnedFolder) -> Void) -> Bool {
        changeFolder(id) { folder in
            let children = folder.children
            body(&folder)
            folder.id = id
            folder.children = children
        }
    }

    /// Changes a pinned item wherever it is. Its id stays.
    @discardableResult
    mutating func updateBookmark(_ id: UUID, _ body: (inout Bookmark) -> Void) -> Bool {
        guard let path = path(of: id) else { return false }
        return change(at: path) { node in
            guard case .bookmark(var bookmark) = node else { return }
            body(&bookmark)
            bookmark.id = id
            node = .bookmark(bookmark)
        }
    }

    private mutating func changeFolder(_ id: UUID, _ body: (inout PinnedFolder) -> Void) -> Bool {
        guard let path = path(of: id) else { return false }
        var found = false
        _ = change(at: path) { node in
            guard case .folder(var folder) = node else { return }
            body(&folder)
            node = .folder(folder)
            found = true
        }
        return found
    }

    private mutating func change(at path: [Int], _ body: (inout PinnedNode) -> Void) -> Bool {
        if path.count == 1 {
            body(&self[path[0]])
            return true
        }
        guard case .folder(var folder) = self[path[0]] else { return false }
        let changed = folder.children.change(at: [Int](path.dropFirst()), body)
        self[path[0]] = .folder(folder)
        return changed
    }

    private static func clamped(_ index: Int, _ count: Int) -> Int {
        Swift.min(Swift.max(index, 0), count)
    }
}

/// Where something dropped on Pinned lands (#76).
enum PinnedDrop: Equatable {
    /// Between two rows: before row `gap` of the outline (its row count: after the last), at `depth`, which puts it
    /// at `place`. A slot that big opens there.
    case slot(gap: Int, depth: Int, place: PinnedPlace)
    /// Inside a folder, at the end. The folder's row highlights.
    case into(UUID)

    /// Where in the tree it lands.
    var place: PinnedPlace {
        switch self {
        case .slot(_, _, let place): place
        case .into(let folder): .end(of: folder)
        }
    }

    /// The folder it lands in, if any.
    var folder: UUID? { place.parent }
}

/// The rows the sidebar draws for a profile's Pinned tree, top to bottom, and where a drop among them lands (#76).
/// Every row has the same height, so where a row is follows from its index.
struct PinnedOutline: Equatable {
    /// How far each level is indented.
    static let indent: CGFloat = 14
    /// Where a top-level row's icon starts, from the rows' left edge.
    static let leading: CGFloat = 8

    struct Row: Equatable, Identifiable {
        enum Kind: Equatable {
            case bookmark(Bookmark)
            /// `expanded` says whether its contents show; `openTabs` counts the tabs inside it, at any depth, that
            /// are open in the window shown.
            case folder(PinnedFolder, expanded: Bool, openTabs: Int)
            /// The item of a collapsed folder whose tab is active: it stays in view, under the folder. For drops it
            /// counts as part of the folder's row.
            case activeUnder(Bookmark, folder: UUID)
            /// "Empty", under an open folder with nothing in it. Dropping on it puts the item in the folder.
            case empty(folder: UUID)
        }

        let kind: Kind
        /// How many levels it's indented. An item under a collapsed folder, and "Empty", are one deeper than
        /// their folder.
        let depth: Int
        /// For each level down to its node, the folder it's in and its index there: what a drop after it at that
        /// level is placed after. For an item under a collapsed folder and for "Empty", the folder's.
        let steps: [PinnedPlace]

        var id: String {
            switch kind {
            case .bookmark(let bookmark), .activeUnder(let bookmark, _): bookmark.id.uuidString
            case .folder(let folder, _, _): "folder-\(folder.id.uuidString)"
            case .empty(let folder): "empty-\(folder.uuidString)"
            }
        }
    }

    let rows: [Row]

    /// - `isExpanded`: whether a folder shows its contents (it's open, or sprang open during a drag).
    /// - `isOpen`: whether a pinned item's tab is open in the window shown.
    /// - `active`: the pinned item whose tab is the window's active one, if any.
    /// - `hiding`: a node left out with everything inside it, as if it weren't there: the one being dragged, when
    ///   working out where it would land. Places are then those of the tree without it.
    /// - `drawnCollapsed`: a folder drawn closed, with nothing under it: one being dragged.
    init(
        tree: [PinnedNode],
        isExpanded: (PinnedFolder) -> Bool,
        isOpen: (Bookmark) -> Bool,
        active: UUID?,
        hiding hidden: UUID? = nil,
        drawnCollapsed: UUID? = nil
    ) {
        var tree = tree
        if let hidden {
            tree.remove(id: hidden)
        }
        var rows: [Row] = []
        func add(_ nodes: [PinnedNode], parent: UUID?, depth: Int, steps: [PinnedPlace]) {
            for (index, node) in nodes.enumerated() {
                let own = steps + [PinnedPlace(parent: parent, index: index)]
                switch node {
                case .bookmark(let bookmark):
                    rows.append(Row(kind: .bookmark(bookmark), depth: depth, steps: own))
                case .folder(let folder):
                    let dragged = folder.id == drawnCollapsed
                    let expanded = !dragged && isExpanded(folder)
                    let inside = folder.children.flattenedBookmarks
                    rows.append(Row(kind: .folder(folder, expanded: expanded, openTabs: inside.filter(isOpen).count), depth: depth, steps: own))
                    if expanded {
                        if folder.children.isEmpty {
                            rows.append(Row(kind: .empty(folder: folder.id), depth: depth + 1, steps: own))
                        } else {
                            add(folder.children, parent: folder.id, depth: depth + 1, steps: own)
                        }
                    } else if !dragged, let active, let item = inside.first(where: { $0.id == active }) {
                        rows.append(Row(kind: .activeUnder(item, folder: folder.id), depth: depth + 1, steps: own))
                    }
                }
            }
        }
        add(tree, parent: nil, depth: 0, steps: [])
        self.rows = rows
    }

    /// Where a drop lands with the middle of what's dropped `y` points below the top of the rows, and the pointer `x`
    /// points from their left edge. `pitch` is a row's height with the spacing after it.
    ///
    /// The middle of a folder's row (and of the item shown under it while it's collapsed, and of "Empty") puts it in
    /// the folder; its top or bottom quarter, and either half of any other row, puts it between rows. Where rows at
    /// different levels meet, as at the bottom of an open folder, the pointer's horizontal position picks the level,
    /// as in Finder's list view.
    func drop(atY y: CGFloat, x: CGFloat, pitch: CGFloat) -> PinnedDrop {
        let position = y / pitch
        guard position.isFinite, position >= 0, !rows.isEmpty else { return slot(gap: 0, x: x) }
        let index = Int(position.rounded(.down))
        guard index < rows.count else { return slot(gap: rows.count, x: x) }
        let fraction = position - CGFloat(index)
        switch rows[index].kind {
        case .bookmark:
            return slot(gap: fraction < 0.5 ? index : index + 1, x: x)
        case .folder(let folder, _, _):
            if fraction < 0.25 {
                return slot(gap: index, x: x)
            }
            let hasItemUnder = index + 1 < rows.count && rows[index + 1].kind.isActiveUnder(folder.id)
            return hasItemUnder || fraction <= 0.75 ? .into(folder.id) : slot(gap: index + 1, x: x)
        case .activeUnder(_, let folder), .empty(let folder):
            return fraction <= 0.75 ? .into(folder) : slot(gap: index + 1, x: x)
        }
    }

    /// The levels a drop before row `gap` can land at, shallowest first, with where each puts it.
    func levels(atGap gap: Int) -> [(depth: Int, place: PinnedPlace)] {
        guard gap > 0, gap <= rows.count else { return [(0, PinnedPlace(parent: nil, index: 0))] }
        let above = rows[gap - 1]
        var steps = above.steps
        switch above.kind {
        case .folder(let folder, expanded: true, _):
            // Just inside an open folder, before its first item.
            return [(above.depth + 1, PinnedPlace(parent: folder.id, index: 0))]
        case .empty(let folder):
            // After "Empty": inside the folder, or after it at any level it's in.
            steps.append(PinnedPlace(parent: folder, index: -1))
        case .bookmark, .folder, .activeUnder:
            break
        }
        let deepest = steps.count - 1
        let shallowest = min(gap < rows.count ? rows[gap].depth : 0, deepest)
        return (shallowest...deepest).map { depth in
            (depth, PinnedPlace(parent: steps[depth].parent, index: steps[depth].index + 1))
        }
    }

    private func slot(gap: Int, x: CGFloat) -> PinnedDrop {
        let levels = levels(atGap: gap)
        // The pointer left of where a level's icons start picks a shallower level.
        let wanted = Int(((x - Self.leading) / Self.indent).rounded(.down))
        let level = levels.last { $0.depth <= wanted } ?? levels[0]
        return .slot(gap: gap, depth: level.depth, place: level.place)
    }
}

private extension PinnedOutline.Row.Kind {
    func isActiveUnder(_ folder: UUID) -> Bool {
        if case .activeUnder(_, let owner) = self { return owner == folder }
        return false
    }
}
