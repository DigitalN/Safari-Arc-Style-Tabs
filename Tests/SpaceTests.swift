import AppKit
import Foundation
import Observation

@main @MainActor struct SpaceTests {
    @MainActor final class ChangeFlag { var value = false }
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

    static func checkEmojiAndEmptySpaces(in directory: URL) throws {
        for emoji in ["🚀", "🫶🏽", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇺🇸", "🏳️‍🌈", "1️⃣", "#️⃣", "☀", "❤️", "🪿"] {
            expect(BrowserSpace.normalizedEmoji(" \(emoji)\n") == emoji, "single emoji supported: \(emoji)")
        }
        for invalid in ["", " ", "hello", "A", "1", "#", "A\u{20E3}", "😀🚀"] {
            expect(BrowserSpace.normalizedEmoji(invalid) == nil, "non-emoji or multiple icons rejected")
        }
        let old = Data("{\"id\":\"\(UUID())\",\"name\":\"Old\",\"icon\":\"house.fill\",\"theme\":\"blue\"}".utf8)
        let legacy = try JSONDecoder().decode(BrowserSpace.self, from: old)
        expect(legacy.emoji == nil && legacy.icon == "house.fill", "old symbol spaces decode unchanged")
        let emojiSpace = BrowserSpace(name: "Family", emoji: "👨‍👩‍👧‍👦")
        let decodedEmoji = try JSONDecoder().decode(BrowserSpace.self, from: JSONEncoder().encode(emojiSpace))
        expect(decodedEmoji == emojiSpace, "composed emoji survives Codable round trip")

        let url = directory.appendingPathComponent("empty-spaces.json")
        let store = TabStore(stateURL: url)
        var commands: [[String: Any]] = []
        store.sendCommand = { commands.append($0) }
        try apply(snapshot([tab(1, active: true), tab(2)]), to: store)
        let original = store.selectedSpace.id
        let empty = store.createSpace()
        expect(commands.isEmpty && store.tabs(in: store.currentWindow!).isEmpty, "new space creates no placeholder tab")
        var edited = empty; edited.emoji = " 👩🏽‍💻 "
        store.updateSpace(edited)
        expect(store.selectedSpace.emoji == "👩🏽‍💻", "space edit saves a trimmed emoji")
        edited.emoji = "two icons 🚀"; store.updateSpace(edited)
        expect(store.selectedSpace.emoji == "👩🏽‍💻", "invalid emoji edit does not overwrite saved icon")
        store.save()
        expect(TabStore(stateURL: url).spaces.first { $0.id == empty.id }?.emoji == "👩🏽‍💻", "emoji survives store relaunch")
        try apply(snapshot([tab(1, active: true), tab(2)], seq: 2), to: store)
        store.dockedWindowTitle = "Tab 1"
        expect(store.selectedSpace.id == empty.id, "routine snapshots and title updates retain an empty selected space")
        for _ in 0..<4 { store.selectSpace(original); store.selectSpace(empty.id) }
        expect(!commands.contains { $0["action"] as? String == "create" }, "repeated switches never create Safari tabs")
        try apply(snapshot([tab(1, active: true), tab(2)], seq: 3), to: store)
        commands.removeAll()
        store.newTab()
        let request = commands.last!["requestId"] as! String
        expect(commands.count == 1 && commands[0]["action"] as? String == "create", "explicit New Tab still creates exactly once")
        _ = store.handleMessage(type: "created", payload: Data(), object: ["requestId": request, "instance": "one", "tabId": 3])
        try apply(snapshot([tab(1), tab(2), tab(3, active: true)], seq: 4), to: store)
        expect(store.selectedSpace.id == empty.id && store.tabs(in: store.currentWindow!).map(\.id) == [3], "explicit new tab belongs to the empty selected space")
        commands.removeAll()
        store.close([tab(3)], instance: "one")
        expect(!commands.contains { $0["action"] as? String == "create" }, "closing a space's last tab creates no replacement")
        try apply(snapshot([tab(1), tab(2, active: true)], seq: 5), to: store)
        expect(store.selectedSpace.id == empty.id, "closing last tab leaves the space selected")
        try apply(snapshot([tab(1, active: true), tab(2)], seq: 6), to: store)
        expect(store.selectedSpace.id == original, "a different Safari tab resumes following its own space")
        store.selectSpace(empty.id)
        try apply(snapshot([tab(1), tab(2), tab(4, active: true)], seq: 7), to: store)
        expect(store.selectedSpace.id == empty.id && store.tabs(in: store.currentWindow!).map(\.id) == [4], "Safari-created tab is assigned to the selected empty space")

        // An earlier activation can finish after the user has selected an empty space.
        let third = store.createSpace()
        store.selectSpace(original); store.selectSpace(empty.id); store.selectSpace(third.id)
        try apply(snapshot([tab(1, active: true), tab(2), tab(4)], seq: 8), to: store)
        try apply(snapshot([tab(1), tab(2), tab(4, active: true)], seq: 9), to: store)
        expect(store.selectedSpace.id == third.id, "late activation confirmations do not bounce out of an empty space")
        commands.removeAll()
        store.addBookmark(url: URL(string: "https://example.com/new-pin")!)
        store.open(store.pinnedBookmarks[0])
        expect(commands.count == 1 && commands[0]["url"] as? String == "https://example.com/new-pin", "opening an empty space's pin creates only the requested page")
        store.selectSpace(original)
        edited = store.spaces.first { $0.id == empty.id }!; edited.emoji = nil
        store.updateSpace(edited)
        expect(store.spaces.first { $0.id == empty.id }?.emoji == nil, "space can return to a symbol icon")

        let windowStore = TabStore(stateURL: directory.appendingPathComponent("empty-window-switch.json"))
        var twoWindows = snapshot([tab(10, active: true)])
        twoWindows.windows.append(.init(id: 20, focused: false, incognito: false, tabs: [tab(20, active: true, windowID: 20)]))
        try apply(twoWindows, to: windowStore)
        let windowHome = windowStore.selectedSpace.id
        windowStore.createSpace()
        let otherWindow = Snapshot(instance: "one", seq: 2, focusedWindowId: 20, lastFocusedWindowId: 20,
            focusChangedAt: 1, windows: twoWindows.windows)
        try apply(otherWindow, to: windowStore)
        expect(windowStore.selectedSpace.id == windowHome, "changing Safari windows clears empty-space background retention")
    }

    static func checkPresentationCaches(in directory: URL) throws {
        let store = TabStore(stateURL: directory.appendingPathComponent("cache-refresh.json"))
        try apply(snapshot([tab(1, active: true), tab(2)]), to: store)
        let home = store.selectedSpace.id
        store.addBookmark(from: tab(1), instance: "one")
        let pin = store.pinnedBookmarks[0]
        let folder = store.createFolder(name: "Cache Parent")
        store.movePinnedItem(.bookmark(pin.id), to: folder.id)
        // Establish warm caches before observing. Hits must still register dependencies.
        _ = store.openTab(for: pin); _ = store.visiblePinnedEntries; _ = store.currentWindow
        let matchingChanged = ChangeFlag(), hierarchyChanged = ChangeFlag(), windowChanged = ChangeFlag()
        withObservationTracking { _ = store.openTab(for: pin) } onChange: { MainActor.assumeIsolated { matchingChanged.value = true } }
        withObservationTracking { _ = store.visiblePinnedEntries } onChange: { MainActor.assumeIsolated { hierarchyChanged.value = true } }
        withObservationTracking { _ = store.currentWindow } onChange: { MainActor.assumeIsolated { windowChanged.value = true } }
        store.toggleFolder(folder.id)
        expect(hierarchyChanged.value && store.visiblePinnedEntries.count == 1, "warm hierarchy cache observes folder collapse")
        try apply(snapshot([tab(1), tab(2, active: true)], seq: 2), to: store)
        expect(matchingChanged.value && windowChanged.value && store.openTab(for: pin)?.active == false,
               "warm pin and window caches observe Safari snapshots")
        store.beginRename(.bookmark(pin.id)); store.commitRename("Updated Pin")
        expect(store.bookmark(pin.id)?.title == "Updated Pin", "bookmark lookup refreshes after rename")
        store.beginRename(.folder(folder.id)); store.commitRename("Updated Parent")
        expect(store.folderPath(folder.id) == "Updated Parent", "folder path refreshes after rename")
        let other = store.createSpace()
        store.moveTabToSpace(tab(2), instance: "one", spaceID: other.id)
        store.selectSpace(home)
        expect(store.openTab(for: pin)?.id == 1, "returning to a space restores its own cached matches")
        store.close([tab(1)], instance: "one")
        expect(store.openTab(for: pin) == nil, "optimistic close invalidates pinned match cache")
        store.removeBookmark(pin)
        expect(store.bookmark(pin.id) == nil && store.pinnedChildren(of: folder.id).isEmpty,
               "removal invalidates lookup and child indexes")

        // Compare against the original one-to-one matching contract using overlapping
        // URLs, scoped/global/profile Favorites, multiple spaces, and an unrelated tab.
        struct Fixture: Encodable {
            var bookmarks: [Bookmark]
            var names: [String] = []
            var orphanNames: [String: String] = [:]
            var spaces: SpaceState
        }
        var state = SpaceState()
        state.spaces = [BrowserSpace(name: "A", arcProfileID: "a"), BrowserSpace(name: "B", arcProfileID: "b"), BrowserSpace(name: "Shared")]
        state.selectedID = state.spaces[0].id
        let pins = (0..<36).map { index in
            Bookmark(title: "Pin \(index)", url: "https://example.com/\(index % 6)/#pin",
                spaceID: index % 4 == 0 ? nil : state.spaces[index % 3].id,
                arcProfileID: index % 8 == 0 ? "a" : nil)
        }
        let live = (1...40).map { index in tab(index, url: "https://example.com/\(index % 6)", active: index == 4) }
        state.memberships = live.map { .init(key: TabKey(instance: "one", tabId: $0.id),
            spaceID: state.spaces[$0.id % 3].id, url: $0.url, windowIndex: 0, privateWindow: false, profile: nil) }
        let url = directory.appendingPathComponent("cache-matching.json")
        try JSONEncoder().encode(Fixture(bookmarks: pins, spaces: state)).write(to: url)
        let matching = TabStore(stateURL: url)
        try apply(snapshot(live), to: matching)
        for _ in 0..<2 {
            for space in state.spaces {
                matching.selectSpace(space.id)
                let selection = matching.currentWindow!
                let visible = pins.filter { $0.spaceID == space.id || ($0.spaceID == nil && ($0.arcProfileID == nil || $0.arcProfileID == space.arcProfileID)) }
                var claimed = Set<Int>(), expected: [UUID: Int] = [:]
                for pin in visible {
                    let candidates = selection.window.tabs.filter {
                        !claimed.contains($0.id) && $0.url?.comparableURL == pin.url.comparableURL &&
                        (pin.spaceID == nil || state.spaceID(for: TabKey(instance: "one", tabId: $0.id)) == pin.spaceID)
                    }
                    if let tab = candidates.first(where: \.active) ?? candidates.first {
                        expected[pin.id] = tab.id; claimed.insert(tab.id)
                    }
                }
                expect(pins.allSatisfy { matching.openTab(for: $0)?.id == expected[$0.id] }, "indexed matching retains duplicate and profile semantics in \(space.name)")
                let ordinary = selection.window.tabs.filter {
                    state.spaceID(for: TabKey(instance: "one", tabId: $0.id)) == space.id && !claimed.contains($0.id)
                }.map(\.id)
                expect(matching.displayedTabs(in: selection).map(\.id) == ordinary, "cached ordinary list retains extra duplicates in \(space.name)")
            }
        }
        var windows = snapshot(live, seq: 2)
        windows.windows.append(BrowserWindow(id: 11, focused: false, incognito: false, tabs: [tab(99, active: true, windowID: 11)]))
        try apply(windows, to: matching)
        _ = matching.currentWindow
        matching.dockedWindowTitle = "Tab 99"
        expect(matching.currentWindow?.window.id == 11, "cached current window follows a changed docked title")
        matching.safariDidTerminate()
        expect(matching.currentWindow == nil && pins.allSatisfy { matching.openTab(for: $0) == nil }, "termination clears cached window and pin matches")
    }
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidetabs-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try checkEmojiAndEmptySpaces(in: dir)
        try checkPresentationCaches(in: dir)
        let store = TabStore(stateURL: dir.appendingPathComponent("state.json"))
        var commands: [[String: Any]] = []
        store.sendCommand = { commands.append($0) }
        let initial = store.selectedSpace.id
        try apply(snapshot([tab(1, active: true), tab(2), tab(3), tab(4)]), to: store)
        expect(store.tabs(in: store.currentWindow!).count == 4, "existing tabs migrate to first space")
        let work = store.createSpace()
        expect(store.selectedSpace.id == work.id, "new space selected")
        expect(commands.isEmpty, "empty space opens without a Safari placeholder")
        store.newTab()
        expect(commands.last?["action"] as? String == "create", "explicit new tab opens in the selected space")
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

        // A pin represents one real tab; presentation must not alter space ownership.
        let presentation = TabStore(stateURL: dir.appendingPathComponent("presentation.json"))
        var presentationCommands: [[String: Any]] = []
        presentation.sendCommand = { presentationCommands.append($0) }
        let sameURL = "https://example.com/pinned"
        try apply(snapshot([tab(1, url: sameURL, active: true), tab(2, url: sameURL), tab(3), tab(4)]), to: presentation)
        presentation.addBookmark(from: tab(1, url: sameURL, active: true), instance: "one")
        let representedPin = presentation.pinnedBookmarks[0]
        expect(presentation.openTab(for: representedPin)?.id == 1 && presentation.openTab(for: representedPin)?.active == true, "selected pinned tab is highlighted in its pin")
        expect(presentation.displayedTabs(in: presentation.currentWindow!).map(\.id) == [2, 3, 4], "pinned tab appears once and intentional extra URL copy stays visible")
        expect(presentation.tabs(in: presentation.currentWindow!).count == 4, "presentation keeps all actual tabs available for space activation")
        expect(presentation.displayedTabs(in: presentation.currentWindow!, showBookmarks: false).count == 4, "hiding bookmarks exposes every live tab")
        try apply(snapshot([tab(1, url: sameURL), tab(2, url: sameURL, active: true), tab(3), tab(4)], seq: 2), to: presentation)
        expect(presentation.openTab(for: representedPin)?.active == false && presentation.displayedTabs(in: presentation.currentWindow!).contains { $0.id == 2 && $0.active }, "extra active duplicate is distinct from explicitly linked pin")
        presentation.addBookmark(from: tab(2, url: sameURL, active: true), instance: "one")
        let secondPin = presentation.pinnedBookmarks.last!
        expect(presentation.openTab(for: representedPin)?.id == 1 && presentation.openTab(for: secondPin)?.id == 2, "duplicate pins retain their own explicit tab links")
        expect(presentation.displayedTabs(in: presentation.currentWindow!).map(\.id) == [3, 4], "each duplicate pin represents one tab")
        presentationCommands.removeAll()
        presentation.closeOtherTabs(than: tab(3), instance: "one")
        expect(presentationCommands.first?["tabIds"] as? [Int] == [4], "close others preserves sidebar pins")
        try apply(snapshot([tab(1, url: "https://example.com/redirect", active: true), tab(2, url: sameURL), tab(3), tab(4)], seq: 3), to: presentation)
        expect(presentation.openTab(for: representedPin)?.id == 1 && !presentation.displayedTabs(in: presentation.currentWindow!).contains { $0.id == 1 }, "navigation or redirect stays attached to its original pin")
        presentation.moveBookmarkToSpace(secondPin, spaceID: nil)
        expect(!presentation.displayedTabs(in: presentation.currentWindow!).contains { $0.id == 2 }, "open favorites also appear only once")
        let hiddenFolder = presentation.createFolder(name: "Parent")
        let hiddenChild = presentation.createFolder(parentID: hiddenFolder.id, name: "Nested")
        presentation.movePinnedItem(.bookmark(representedPin.id), to: hiddenChild.id)
        // Moving within a space retains the tab link, even for duplicate URLs.
        try apply(snapshot([tab(1, url: sameURL), tab(2, url: sameURL), tab(3, active: true), tab(4)], seq: 4), to: presentation)
        presentation.toggleFolder(hiddenFolder.id); presentation.toggleFolder(hiddenChild.id)
        try apply(snapshot([tab(1, url: sameURL, active: true), tab(2, url: sameURL), tab(3), tab(4)], seq: 5), to: presentation)
        expect(presentation.folder(hiddenFolder.id)?.isExpanded == true && presentation.folder(hiddenChild.id)?.isExpanded == true, "activating a nested pin reveals all its ancestors")
        presentation.toggleFolder(hiddenFolder.id)
        try apply(snapshot([tab(1, url: sameURL, active: true), tab(2, url: sameURL), tab(3), tab(4)], seq: 6), to: presentation)
        expect(presentation.folder(hiddenFolder.id)?.isExpanded == false, "routine snapshots respect a user's deliberate folder collapse")
        presentationCommands.removeAll()
        presentation.moveTab(tab(4), instance: "one", to: 0)
        expect(presentationCommands.last?["index"] as? Int == 2 && presentation.displayedTabs(in: presentation.currentWindow!).map(\.id) == [4, 3], "reorder maps ordinary tab positions past hidden pinned tabs")
        presentation.removeBookmark(representedPin)
        expect(presentation.displayedTabs(in: presentation.currentWindow!).contains { $0.id == 1 }, "unpinning reveals the existing Safari tab without reopening it")
        let unrelatedSpace = presentation.createSpace()
        presentationCommands.removeAll()
        try apply(snapshot([tab(1, url: sameURL), tab(2, url: sameURL), tab(3), tab(4)], seq: 7), to: presentation)
        // Explicitly move an ordinary tab to this space; another space's pins cannot hide it.
        presentation.moveTabToSpace(tab(3), instance: "one", spaceID: unrelatedSpace.id)
        expect(presentation.displayedTabs(in: presentation.currentWindow!).contains { $0.id == 3 }, "other spaces' pins do not hide ordinary tabs")

        let fallback = TabStore(stateURL: dir.appendingPathComponent("fallback.json"))
        fallback.addBookmark(url: URL(string: sameURL)!)
        fallback.addBookmark(url: URL(string: sameURL)!)
        try apply(snapshot([tab(1, url: sameURL), tab(2, url: sameURL, active: true), tab(3, url: sameURL)]), to: fallback)
        let assignments = fallback.pinnedBookmarks.compactMap { fallback.openTab(for: $0)?.id }
        expect(Set(assignments).count == 2 && fallback.displayedTabs(in: fallback.currentWindow!).count == 1, "unlinked duplicate pins consume distinct tabs without hiding every URL match")
        fallback.save()
        let fallbackRestored = TabStore(stateURL: dir.appendingPathComponent("fallback.json"))
        try apply(snapshot([tab(11, url: sameURL), tab(12, url: sameURL, active: true), tab(13, url: sameURL)], instance: "new"), to: fallbackRestored)
        expect(fallbackRestored.displayedTabs(in: fallbackRestored.currentWindow!).count == 1 && fallbackRestored.pinnedBookmarks.contains { fallbackRestored.openTab(for: $0)?.active == true }, "pin matching and highlighting recover after app and Safari restart")

        var routing = SidebarSwipeRoute()
        expect(routing.route(at: .icons, began: true, cancelled: false) == .icons, "icon-strip gesture goes to native horizontal scrolling")
        expect(routing.route(at: .tabs, began: false, cancelled: false) == .icons, "icon scrolling and momentum cannot turn into a space switch")
        expect(routing.route(at: .tabs, began: true, cancelled: false) == .tabs, "new tab-area gesture still switches spaces")
        expect(routing.route(at: .icons, began: false, cancelled: true) == .tabs && routing.route(at: .icons, began: false, cancelled: false) == .icons, "cancelling releases gesture ownership")
        expect(routing.route(at: .outside, began: true, cancelled: false) == .outside, "gestures outside sidebar are not captured")

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
