import AppKit
import Foundation

@main @MainActor struct SpaceTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("FAILED: \(message)") }
    }
    static func tab(_ id: Int, index: Int? = nil, url: String? = nil, active: Bool = false, windowID: Int = 10) -> BrowserTab {
        BrowserTab(id: id, windowId: windowID, index: index ?? id - 1, title: "Tab \(id)", url: url ?? "https://example.com/\(id)", active: active, pinned: false, audible: false, muted: false, loading: false)
    }
    static func snapshot(_ tabs: [BrowserTab], instance: String = "one", seq: Int = 1, privateWindow: Bool = false) -> Snapshot {
        Snapshot(instance: instance, seq: seq, focusedWindowId: 10, lastFocusedWindowId: 10, focusChangedAt: 0,
                 windows: [BrowserWindow(id: 10, focused: true, incognito: privateWindow, tabs: tabs)])
    }
    static func apply(_ snapshot: Snapshot, to store: TabStore) throws {
        let payload = try JSONEncoder().encode(snapshot)
        _ = store.handleMessage(type: "snapshot", payload: payload, object: [:])
    }
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidetabs-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TabStore(stateURL: dir.appendingPathComponent("state.json"))
        var commands: [[String: Any]] = []
        store.sendCommand = { commands.append($0) }
        let initial = store.selectedSpace.id
        try apply(snapshot([tab(1, active: true), tab(2), tab(3), tab(4)]), to: store)
        expect(store.tabs(in: store.currentWindow!).count == 4, "existing tabs migrate to first space")
        let work = store.createSpace()
        expect(store.selectedSpace.id == work.id, "new space selected")
        expect(commands.last?["action"] as? String == "create", "empty space creates a Safari tab")
        let request = commands.last!["requestId"] as! String
        store.moveTabToSpace(tab(2), instance: "one", spaceID: work.id)
        store.moveTabToSpace(tab(4), instance: "one", spaceID: work.id)
        expect(store.tabs(in: store.currentWindow!).map(\.id) == [2, 4], "tabs isolated in selected space")
        store.moveTab(tab(4), instance: "one", to: 0)
        expect(commands.last?["index"] as? Int == 1, "filtered reorder maps to Safari index")
        expect(store.currentWindow!.window.tabs.map(\.id) == [1, 4, 2, 3], "other-space tab order retained")
        store.addBookmark(from: tab(2), instance: "one")
        expect(store.pinnedBookmarks.count == 1, "pins belong to selected space")
        let pin = store.pinnedBookmarks[0]
        store.addBookmark(from: tab(4), instance: "one")
        store.moveBookmarkToSpace(store.pinnedBookmarks.last!, spaceID: nil)
        expect(store.favorites.count == 1, "favorites are global")
        store.selectSpace(initial)
        expect(store.pinnedBookmarks.isEmpty && store.favorites.count == 1, "pins hidden and favorites retained on switch")
        expect(commands.last?["tabId"] as? Int == 1, "space switch activates remembered tab")
        store.open(store.favorites[0])
        expect(store.selectedSpace.id == initial, "opening a favorite keeps current space")
        store.selectSpace(work.id)
        // Reply for an earlier create must retain its originally requested space.
        store.selectSpace(initial)
        _ = store.handleMessage(type: "created", payload: Data(), object: ["requestId": request, "instance": "one", "tabId": 5])
        try apply(snapshot([tab(1, active: true), tab(2), tab(3), tab(4), tab(5)], seq: 2), to: store)
        expect(store.selectedSpace.id == initial, "late created reply does not jump spaces")
        store.selectSpace(work.id)
        expect(store.tabs(in: store.currentWindow!).map(\.id) == [2, 5], "created tab assigned to requested space")
        commands.removeAll()
        store.closeOtherTabs(than: tab(2), instance: "one")
        expect(Set(commands.first?["tabIds"] as? [Int] ?? []) == [5], "close other tabs confined to space")
        store.save()
        let restored = TabStore(stateURL: dir.appendingPathComponent("state.json"))
        expect(restored.spaces.count == 2 && restored.pinnedBookmarks.count == 1, "spaces and pins reload")
        expect(restored.favorites.count == 1, "favorites reload")
        restored.sendCommand = { _ in }
        try apply(snapshot([tab(11, url: "https://example.com/1", active: true), tab(12, url: "https://example.com/2"), tab(13, url: "https://example.com/3"), tab(14, url: "https://example.com/4")], instance: "restart"), to: restored)
        restored.selectSpace(work.id)
        expect(restored.tabs(in: restored.currentWindow!).map(\.id) == [12], "Safari restart restores URL membership")
        restored.deleteSpace(work.id)
        expect(restored.spaces.count == 1 && restored.tabs(in: restored.currentWindow!).count == 4, "deleting space moves tabs without closing")
        expect(restored.pinnedBookmarks.first?.id == pin.id, "deleting space moves pins")
        restored.deleteSpace(initial)
        expect(restored.spaces.count == 1, "last space protected")
        let legacy = dir.appendingPathComponent("legacy.json")
        try Data("{\"bookmarks\":[{\"id\":\"\(UUID())\",\"title\":\"Old\",\"url\":\"https://old.example\"}],\"names\":[],\"orphanNames\":{}}".utf8).write(to: legacy)
        let migrated = TabStore(stateURL: legacy)
        expect(migrated.spaces.count == 1 && migrated.favorites.count == 1, "legacy state migrates without losing bookmarks")

        var state = SpaceState()
        let first = state.selectedID
        state.spaces.append(BrowserSpace(name: "Work"))
        let second = state.spaces[1].id
        let duplicates = [tab(1, url: "https://duplicate.example", active: true), tab(2, url: "https://duplicate.example")]
        state.reconcile(snapshot(duplicates), liveInstances: ["one"])
        state.assign(TabKey(instance: "one", tabId: 2), to: second)
        state.reconcile(snapshot([tab(11, url: "https://duplicate.example"), tab(12, url: "https://duplicate.example")], instance: "two"), liveInstances: ["two"])
        expect(state.spaceID(for: TabKey(instance: "two", tabId: 11)) == first && state.spaceID(for: TabKey(instance: "two", tabId: 12)) == second, "duplicate URLs retain separate memberships")
        state.reconcile(snapshot([tab(20)], instance: "private", privateWindow: true), liveInstances: ["two", "private"])
        expect(!state.persistentCopy.memberships.contains { $0.privateWindow }, "private memberships excluded from persistence")
        state.reconcile(snapshot([tab(11, url: "https://duplicate.example")], instance: "two", seq: 2), liveInstances: ["two", "private"])
        expect(state.spaceID(for: TabKey(instance: "two", tabId: 12)) == nil, "closed tabs pruned")
        let decoded = try JSONDecoder().decode(SpaceState.self, from: JSONEncoder().encode(state))
        expect(decoded == state, "space state codable round trip")

        let permissionStore = TabStore(stateURL: dir.appendingPathComponent("permission-state.json"))
        var hidden = tab(90, active: true)
        hidden.url = nil
        hidden.title = nil
        try apply(snapshot([hidden]), to: permissionStore)
        let heartbeat = permissionStore.handleMessage(type: "heartbeat", payload: Data(), object: ["instance": "one", "seq": 1])
        expect(heartbeat["needSnapshot"] as? Bool == true, "heartbeat refreshes while website access is missing")
        try apply(snapshot([tab(90, active: true)], seq: 2), to: permissionStore)
        let allowedHeartbeat = permissionStore.handleMessage(type: "heartbeat", payload: Data(), object: ["instance": "one", "seq": 2])
        expect(allowedHeartbeat["needSnapshot"] as? Bool == false, "heartbeat stops requesting data once website access works")

        // Folders organize persistent pins inside a space, including mixed sibling order.
        let folderURL = dir.appendingPathComponent("folders.json")
        let tree = TabStore(stateURL: folderURL)
        tree.sendCommand = { _ in }
        try apply(snapshot([tab(1, active: true), tab(2)]), to: tree)
        let homeID = tree.selectedSpace.id
        let projects = tree.createFolder(name: "Projects")
        let client = tree.createFolder(parentID: projects.id, name: "Client")
        let references = tree.createFolder(parentID: client.id, name: "References")
        tree.addBookmark(from: tab(1), instance: "one", folderID: references.id)
        let nestedPin = tree.pinnedBookmarks[0]
        tree.addBookmark(from: tab(2), instance: "one")
        let rootPin = tree.pinnedBookmarks[1]
        expect(tree.visiblePinnedEntries.map(\.depth) == [0, 1, 2, 3, 0], "nested folders render the correct depth")
        expect(tree.folderPath(references.id) == "Projects / Client / References", "folder paths disambiguate nested destinations")
        tree.toggleFolder(projects.id)
        expect(tree.visiblePinnedEntries.map(\.item) == [.folder(projects.id), .bookmark(rootPin.id)], "collapsing hides all descendants")
        expect(tree.pinnedBookmarks.count == 2 && tree.pinnedEntries(includeCollapsed: true).count == 5, "collapse preserves pins and move destinations")
        tree.movePinnedItem(.bookmark(rootPin.id), to: client.id, at: 0)
        expect(tree.folder(projects.id)?.isExpanded == false, "moving into a nested folder respects ancestor collapse")
        tree.toggleFolder(projects.id)
        expect(tree.pinnedChildren(of: client.id) == [.bookmark(rootPin.id), .folder(references.id)], "folders and bookmarks share sibling ordering")
        tree.reorderPinnedItem(.folder(references.id), direction: -1)
        expect(tree.pinnedChildren(of: client.id) == [.folder(references.id), .bookmark(rootPin.id)], "mixed folder/pin reordering")
        let beforeCycle = tree.folderState.order
        tree.movePinnedItem(.folder(projects.id), to: references.id)
        expect(tree.folder(projects.id)?.parentID == nil && tree.folderState.order == beforeCycle, "descendant nesting rejected without changing order")
        expect(!tree.canMovePinnedItem(.folder(client.id), into: client.id), "self nesting rejected")
        tree.movePinnedItem(.bookmark(rootPin.id), to: nil)
        expect(tree.bookmark(rootPin.id)?.folderID == nil, "pin moves back to top level")
        tree.beginRename(.folder(references.id))
        tree.commitRename("  Research  ")
        expect(tree.folder(references.id)?.name == "Research", "folder rename trims whitespace")
        tree.beginRename(.folder(references.id))
        tree.commitRename("   ")
        expect(tree.folder(references.id)?.name == "Research", "blank rename preserves name")
        tree.toggleFolder(references.id)
        tree.save()
        let loadedTree = TabStore(stateURL: folderURL)
        expect(loadedTree.folders.count == 3 && loadedTree.bookmark(nestedPin.id)?.folderID == references.id, "folder membership survives relaunch")
        expect(loadedTree.folder(references.id)?.isExpanded == false, "expanded state survives relaunch")
        expect(loadedTree.pinnedChildren(of: client.id) == tree.pinnedChildren(of: client.id), "sibling ordering survives relaunch")
        expect(loadedTree.spaces.count == 1 && loadedTree.customNames == tree.customNames, "folders preserve the existing state fields")
        let other = tree.createSpace()
        tree.movePinnedItem(.folder(projects.id), to: nil, spaceID: other.id)
        expect(tree.folders.allSatisfy { $0.spaceID == other.id }, "moving a folder across spaces moves every descendant")
        expect(tree.bookmark(nestedPin.id)?.spaceID == other.id && tree.bookmark(rootPin.id)?.spaceID == homeID, "subtree move changes only contained pins")
        tree.selectSpace(homeID)
        expect(!tree.visiblePinnedEntries.contains { $0.item == .folder(projects.id) }, "folders isolated by space")
        tree.selectSpace(other.id)
        var liveCommands: [[String: Any]] = []
        tree.sendCommand = { liveCommands.append($0) }
        tree.removeFolder(client.id)
        expect(tree.folder(references.id)?.parentID == projects.id, "removing a folder promotes its subfolder")
        expect(tree.bookmark(nestedPin.id)?.folderID == references.id, "removal retains deeper pin membership")
        tree.removeFolder(references.id)
        expect(tree.bookmark(nestedPin.id)?.folderID == projects.id, "removing a leaf folder promotes its pins")
        expect(liveCommands.isEmpty, "folder removal sends no Safari close commands")
        tree.moveBookmarkToSpace(tree.bookmark(nestedPin.id)!, spaceID: nil)
        expect(tree.favorites.contains { $0.id == nestedPin.id } && tree.bookmark(nestedPin.id)?.folderID == nil, "moving a pin to favorites clears folder membership")
        let child = tree.createFolder(parentID: projects.id, name: "Child")
        tree.addBookmark(url: URL(string: "https://example.com/nested")!, folderID: child.id)
        tree.deleteSpace(other.id)
        expect(tree.folders.allSatisfy { $0.spaceID == homeID } && tree.folder(child.id)?.parentID == projects.id, "deleting a space preserves the entire folder hierarchy")
        expect(tree.pinnedBookmarks.contains { $0.folderID == child.id }, "deleting space preserves nested pins")
        tree.addBookmark(url: URL(string: "https://example.com/orphan")!, folderID: UUID())
        expect(tree.pinnedBookmarks.last?.folderID == nil, "unknown destination falls back safely to top level")

        // Defensive load: damaged folder parent chains cannot hide data or recurse forever.
        let cycleA = UUID(), cycleB = UUID(), foreign = UUID()
        var damaged = FolderState(folders: [
            PinnedFolder(id: cycleA, name: "A", spaceID: homeID, parentID: cycleB),
            PinnedFolder(id: cycleB, name: "B", spaceID: homeID, parentID: cycleA),
            PinnedFolder(id: foreign, name: "Foreign", spaceID: UUID(), parentID: UUID())
        ], order: [.folder(cycleA), .folder(cycleA), .folder(UUID())])
        var damagedPins = [Bookmark(title: "Orphan", url: "https://example.com", spaceID: homeID, folderID: UUID())]
        damaged.normalize(bookmarks: &damagedPins, spaces: [BrowserSpace(id: homeID)])
        expect(damaged.folders.allSatisfy { $0.spaceID == homeID }, "unknown folder spaces repaired")
        expect(damaged.folders.first { $0.id == foreign }?.parentID == nil && damagedPins[0].folderID == nil, "missing parents repaired without dropping pins")
        expect(Set(damaged.order).count == damaged.order.count && damaged.order.count == 4, "stale and duplicate order entries normalized")
        expect(damaged.folders.contains { $0.id == cycleA && $0.parentID == nil } || damaged.folders.contains { $0.id == cycleB && $0.parentID == nil }, "cycles repaired when loading")
        let shallowCopy = try JSONDecoder().decode(FolderState.self, from: JSONEncoder().encode(damaged))
        expect(shallowCopy.folders == damaged.folders && shallowCopy.order == damaged.order, "folder tree codable round trip")

        var swipe = SpaceSwipe()
        var result = swipe.update(x: -20, y: 1, began: true, ended: false, cancelled: false, momentum: false)
        expect(result.consume && result.direction == nil, "horizontal gesture captured before threshold")
        result = swipe.update(x: -30, y: 1, began: false, ended: false, cancelled: false, momentum: false)
        expect(result.direction == 1, "left swipe switches to next space")
        expect(swipe.update(x: -100, y: 0, began: false, ended: true, cancelled: false, momentum: false).direction == nil, "long swipe switches only once")
        expect(swipe.update(x: -100, y: 0, began: false, ended: false, cancelled: false, momentum: true).direction == nil, "momentum cannot switch")
        result = swipe.update(x: 60, y: 1, began: true, ended: false, cancelled: false, momentum: false)
        expect(result.direction == -1, "right swipe switches to previous space")
        result = swipe.update(x: 1, y: -20, began: true, ended: false, cancelled: false, momentum: false)
        expect(!result.consume && result.direction == nil, "vertical scroll passes through")
        result = swipe.update(x: -100, y: -1, began: false, ended: true, cancelled: false, momentum: false)
        expect(!result.consume && result.direction == nil, "vertical axis stays locked")
        _ = swipe.update(x: -20, y: 0, began: true, ended: false, cancelled: false, momentum: false)
        result = swipe.update(x: -100, y: 0, began: false, ended: false, cancelled: true, momentum: false)
        expect(result.direction == nil, "cancelled gesture cannot switch")
        result = swipe.update(x: -6, y: 0, began: true, ended: true, cancelled: false, momentum: false)
        expect(!result.consume && result.direction == nil, "small movement cannot switch")
        print("Passed \(checks) spaces, folders, and swipe checks.")
    }
}
