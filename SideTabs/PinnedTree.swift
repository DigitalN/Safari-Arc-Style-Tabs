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

    /// Where something dragged over the rows lands, and where the room it takes up is drawn, from where that room is
    /// drawn now (`spacer`: the gap the open slot is in, or where it stays while a folder is the target; nil when
    /// nothing has opened yet) and from the middle of what's dragged, `y` points below the top of the rows. `x` is the
    /// pointer, from the rows' left edge, and `pitch` a row's height with the spacing after it.
    ///
    /// It's decided against the rows where they're drawn, with the room open at `spacer`, so the slot stays under
    /// what's dragged, as it did before there were folders: moving it past a row takes about half a row either way.
    /// The middle half of a folder's row (and the item shown under it while it's collapsed, and "Empty") puts it in
    /// the folder, and the room stays where it was, so the folder doesn't move out from under the pointer; its top
    /// and bottom quarters put it just above or below the folder. Where rows at different levels meet, as at the
    /// bottom of an open folder, the pointer's horizontal position picks the level, as in Finder's list view.
    ///
    /// The result is the same when it's worked out again from its own `spacer` at the same position, so nothing
    /// flips back and forth while the pointer rests or moves.
    func dragStep(spacer: Int?, centerY y: CGFloat, x: CGFloat, pitch: CGFloat) -> (drop: PinnedDrop, spacer: Int?) {
        let count = rows.count
        let room = spacer.map { min(max($0, 0), count) }
        func opened(_ gap: Int) -> (drop: PinnedDrop, spacer: Int?) { (slot(gap: gap, x: x), gap) }
        let middle = y / pitch
        guard middle.isFinite, count > 0 else { return opened(0) }
        // Where a row is drawn: one row lower from the open room down.
        func top(_ index: Int) -> CGFloat { CGFloat(index) + (room.map { index >= $0 } == true ? 1 : 0) }
        if let room, middle >= CGFloat(room), middle < CGFloat(room) + 1 {
            return opened(room)
        }
        guard let index = rows.indices.first(where: { middle >= top($0) && middle < top($0) + 1 }) else {
            return opened(middle < top(0) ? 0 : count)
        }
        // A pinned item: the room moves to where it's drawn, so it's under what's dragged again.
        guard let (folder, first, last, isEmpty) = folderBlock(at: index, room: room) else {
            return opened(top(index) == CGFloat(index) ? index : index + 1)
        }
        let blockTop = top(first), blockBottom = top(last) + 1
        if middle >= (isEmpty ? blockTop : blockTop + 0.25), middle <= blockBottom - 0.25 {
            return (.into(folder), room)
        }
        return opened(middle < blockTop + 0.25 ? first : last + 1)
    }

    /// The rows a drop on row `index` counts as a folder's: a folder's row and the item shown under it while it's
    /// collapsed (or "Empty", which is one of its own). Nil for a pinned item's row. `room` is never inside one.
    private func folderBlock(at index: Int, room: Int?) -> (folder: UUID, first: Int, last: Int, isEmpty: Bool)? {
        switch rows[index].kind {
        case .bookmark:
            return nil
        case .empty(let folder):
            return (folder, index, index, true)
        case .activeUnder(_, let folder):
            return room == index ? (folder, index, index, false) : (folder, index - 1, index, false)
        case .folder(let folder, _, _):
            let hasItemUnder = index + 1 < rows.count && rows[index + 1].kind.isActiveUnder(folder.id) && room != index + 1
            return (folder.id, index, hasItemUnder ? index + 1 : index, false)
        }
    }

    /// Where the room a drag takes up goes when rows come or go above or around it (a folder springing open, or one
    /// that sprang open closing again): after the same rows that were above it. A folder that springs open with the
    /// room below it gets the room just inside it, above what it shows.
    static func spacer(_ spacer: Int?, from before: PinnedOutline, to after: PinnedOutline) -> Int? {
        guard let spacer else { return nil }
        let remaining = Set(after.rows.map(\.id))
        return before.rows.prefix(min(spacer, before.rows.count)).filter { remaining.contains($0.id) }.count
    }

    /// The row of the pinned item or folder with this id, which is the gap its room is in before it moves.
    func index(of node: UUID) -> Int? {
        rows.firstIndex { $0.kind.node == node }
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

extension PinnedOutline.Row.Kind {
    /// The pinned item or folder the row stands for. Nil for "Empty".
    var node: UUID? {
        switch self {
        case .bookmark(let bookmark), .activeUnder(let bookmark, _): bookmark.id
        case .folder(let folder, _, _): folder.id
        case .empty: nil
        }
    }

    fileprivate func isActiveUnder(_ folder: UUID) -> Bool {
        if case .activeUnder(_, let owner) = self { return owner == folder }
        return false
    }
}
