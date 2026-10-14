import Foundation

struct PinnedFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var spaceID: UUID
    var parentID: UUID?
    var isExpanded = true
}

enum PinnedItem: Codable, Hashable, Identifiable {
    case folder(UUID)
    case bookmark(UUID)
    var id: Self { self }
}

struct PinnedEntry: Identifiable {
    var item: PinnedItem
    var depth: Int
    var id: PinnedItem { item }
}

/// Order is shared by the tree; filtering it to a parent yields that parent's
/// sibling order. Folder and bookmark IDs remain stable across moves and relaunches.
struct FolderState: Codable {
    var folders: [PinnedFolder] = []
    var order: [PinnedItem] = []

    func children(spaceID: UUID, parentID: UUID?, bookmarks: [Bookmark]) -> [PinnedItem] {
        let eligible = folders.filter { $0.spaceID == spaceID && $0.parentID == parentID }.map { PinnedItem.folder($0.id) }
            + bookmarks.filter { $0.spaceID == spaceID && $0.folderID == parentID }.map { PinnedItem.bookmark($0.id) }
        let valid = Set(eligible)
        let ordered = order.filter { valid.contains($0) }
        return ordered + eligible.filter { !ordered.contains($0) }
    }

    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var pending = [id]
        while let parent = pending.popLast() {
            for folder in folders where folder.parentID == parent && !result.contains(folder.id) {
                result.insert(folder.id)
                pending.append(folder.id)
            }
        }
        return result
    }

    mutating func normalize(bookmarks: inout [Bookmark], spaces: [BrowserSpace]) {
        guard let firstSpace = spaces.first?.id else { return }
        var seen = Set<UUID>()
        folders = folders.filter { seen.insert($0.id).inserted }
        for i in folders.indices {
            if !spaces.contains(where: { $0.id == folders[i].spaceID }) { folders[i].spaceID = firstSpace }
        }
        for i in folders.indices {
            var ancestors: Set<UUID> = [folders[i].id]
            var parent = folders[i].parentID
            while let id = parent {
                guard ancestors.insert(id).inserted,
                      let node = folders.first(where: { $0.id == id }), node.spaceID == folders[i].spaceID else {
                    folders[i].parentID = nil
                    break
                }
                parent = node.parentID
            }
        }
        for i in bookmarks.indices {
            if let folderID = bookmarks[i].folderID,
               !folders.contains(where: { $0.id == folderID && $0.spaceID == bookmarks[i].spaceID }) {
                bookmarks[i].folderID = nil
            }
        }
        let all = folders.map { PinnedItem.folder($0.id) } + bookmarks.map { PinnedItem.bookmark($0.id) }
        let valid = Set(all)
        var included = Set<PinnedItem>()
        order = order.filter { valid.contains($0) && included.insert($0).inserted }
        order += all.filter { included.insert($0).inserted }
    }
}
