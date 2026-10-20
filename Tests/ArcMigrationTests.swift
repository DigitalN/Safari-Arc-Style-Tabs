import AppKit
import Foundation

@main @MainActor struct ArcMigrationTests {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("FAILED: \(message)") }
    }
    static func item(_ id: String, _ kind: String, children: [String] = [], title: String? = nil, url: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [:]
        if kind == "tab" { payload = ["savedURL": url ?? "https://example.com/same", "savedTitle": title ?? id] }
        return ["id": id, "title": title ?? id, "data": [kind: payload], "childrenIds": children]
    }
    static func fixture(extra: Bool = false, changed: Bool = false) -> [String: Any] {
        var items = [item("p", "itemContainer", children: ["f", "split"]), item("u", "itemContainer", children: ["today", "today2"]),
            item("p2", "itemContainer"), item("u2", "itemContainer"),
            item("fav", "itemContainer", children: ["star"]), item("fav2", "itemContainer", children: ["star2"]),
            item("f", "list", children: extra ? ["n", "pin", "new"] : ["n", "pin"], title: "Folder"),
            item("n", "list", children: ["nested"], title: "Nested"), item("nested", "tab"),
            item("pin", "tab", title: changed ? "Changed in Arc" : "Original"),
            item("split", "splitView", children: ["a", "b"]), item("a", "tab"), item("b", "tab"),
            item("star", "tab"), item("star2", "tab"), item("today", "tab"), item("today2", "tab")]
        if extra { items.append(item("new", "tab")) }
        let custom: [String: Any] = ["custom": ["_0": ["directoryBasename": "Profile 1", "machineID": "test"]]]
        func space(_ id: String, _ title: String, _ profile: [String: Any], _ p: String, _ u: String) -> [String: Any] {
            ["id": id, "title": title, "profile": profile, "customInfo": ["iconType": ["emoji_v2": "👩🏽‍💻"]],
             "newContainerIDs": [["unpinned": ["_0": ["shared": [:]]]], u, ["pinned": [:]], p]]
        }
        return ["version": 1, "sidebar": ["containers": [["global": [:]], [
            "spaces": ["s", space("s", "One", ["default": true], "p", "u"), "s2", space("s2", "Two", custom, "p2", "u2")],
            "items": items.flatMap { [$0["id"]!, $0] }, "topAppsContainerIDs": [["default": true], "fav", custom, "fav2"]
        ]]], "firebaseSyncState": ["items": ["stale", item("stale", "tab")]]]
    }
    static func write(_ object: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
    static func snapshot(_ tabs: [BrowserTab] = [], privateWindow: Bool = false) -> Snapshot {
        .init(instance: "safari", seq: 1, focusedWindowId: 10, lastFocusedWindowId: 10, focusChangedAt: 0,
              windows: [.init(id: 10, focused: true, incognito: privateWindow, tabs: tabs)], capabilities: ["arcMigrationV1"])
    }
    static func apply(_ snapshot: Snapshot, _ store: TabStore) throws {
        _ = store.handleMessage(type: "snapshot", payload: try JSONEncoder().encode(snapshot), object: [:])
    }
    static func main() throws {
        if CommandLine.arguments.contains("--inspect-arc") {
            let source = try ArcImportReader.read()
            print("Live Arc preview: \(source.spaces.count) spaces, \(source.folders) folders, \(source.count(.pin)) pins, \(source.count(.favorite)) Favorites, \(source.count(.tab)) open tabs, \(source.entries.filter { $0.issue != nil }.count) manual items; \(source.containerCount) containers, \(source.sourceItemCount) source records. No import performed.")
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("arc-import-tests-\(UUID())")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("StorableSidebar.json"), state = temp.appendingPathComponent("state.json")
        try write(fixture(), file)
        let source = try ArcImportReader.read(file)
        expect(source.spaces.map(\.name) == ["One", "Two"], "active space order retained; sync cache excluded")
        expect(source.folders == 2 && source.count(.pin) == 4 && source.count(.tab) == 2 && source.count(.favorite) == 2, "complete source accounting")
        expect(source.entries.filter { $0.splitID != nil }.map(\.id) == ["item:a", "item:b"], "split children kept adjacent with provenance")
        expect(source.profiles == ["Default", "Profile 1"], "profiles distinguished without merging favorites")
        let store = TabStore(stateURL: state)
        let initial = store.selectedSpace.id
        store.addBookmark(url: URL(string: "https://example.com/existing")!)
        store.save()
        let beforePreview = try Data(contentsOf: state)
        for entry in source.entries { _ = store.arcDisposition(entry) }
        let afterPreview = try Data(contentsOf: state)
        expect(afterPreview == beforePreview, "preview leaves state byte-for-byte unchanged")
        var commands: [[String: Any]] = []; store.sendCommand = { commands.append($0) }
        let selected = Set(source.spaces.map(\.id))
        let receipt = try store.importArc(source, selectedSpaces: selected, includeFavorites: true)
        expect(commands.isEmpty && store.selectedSpace.id == initial, "bulk import never opens tabs or selects empty spaces")
        expect(store.spaces.count == 3 && store.folders.count == 2 && store.bookmarks.count == 7, "existing data preserved alongside imported hierarchy")
        let folderID = store.arcMigration.records["item:f"]!.targetID, nestedID = store.arcMigration.records["item:n"]!.targetID
        let spaceID = store.arcMigration.records["space:s"]!.targetID
        expect(store.spaces.first { $0.id == spaceID }?.emoji == "👩🏽‍💻", "Arc emoji icons preserved for new imports")
        expect(store.folder(nestedID)?.parentID == folderID, "nested folder parent retained")
        expect(store.bookmark(store.arcMigration.records["item:nested"]!.targetID)?.folderID == nestedID, "deep pin assigned correctly")
        expect(store.pinnedChildren(of: folderID, spaceID: spaceID) == [.folder(nestedID), .bookmark(store.arcMigration.records["item:pin"]!.targetID)], "mixed folder and pin sibling ordering")
        expect(store.arcPendingTabs.count == 2 && receipt.conflicts.isEmpty, "open tabs safely queued")
        expect(store.bookmarks.filter { $0.url == "https://example.com/same" }.count == 6, "identical URLs with distinct source IDs preserved")
        expect(FileManager.default.fileExists(atPath: receipt.backupPath + "/before.json") && FileManager.default.fileExists(atPath: receipt.backupPath + "/Arc-sidebar.json"), "private backup created before import")
        let backupPermissions = try FileManager.default.attributesOfItem(atPath: receipt.backupPath)[.posixPermissions] as? Int
        expect(backupPermissions == 0o700, "backup directory private")
        expect(source.entries.allSatisfy { store.arcDisposition($0) == .retained }, "stable signatures after import")
        let second = try store.importArc(source, selectedSpaces: selected, includeFavorites: true)
        expect(second.added == 0 && second.conflicts.isEmpty && store.bookmarks.count == 7, "repeat import is a no-op")
        let loaded = TabStore(stateURL: state)
        expect(loaded.arcMigration.records.count == store.arcMigration.records.count && loaded.arcPendingTabs.count == 2 && loaded.folders.count == 2, "ledger and hierarchy survive restart together")
        loaded.selectSpace(spaceID)
        expect(loaded.favorites.filter { $0.arcProfileID != nil }.map(\.arcProfileID) == ["Default"], "favorites scoped to source profile")
        loaded.selectSpace(loaded.arcMigration.records["space:s2"]!.targetID)
        expect(loaded.favorites.filter { $0.arcProfileID != nil }.map(\.arcProfileID) == ["Profile 1"], "other profile favorites separate")
        store.beginRename(.bookmark(store.arcMigration.records["item:pin"]!.targetID)); store.commitRename("Edited in Safari")
        expect(store.arcDisposition(source.entries.first { $0.id == "item:pin" }!) == .conflict, "destination edits detected")
        try write(fixture(extra: true, changed: true), file)
        do { _ = try store.importArc(source, selectedSpaces: selected, includeFavorites: true); fatalError("stale preview imported") } catch { checks += 1 }
        let changed = try ArcImportReader.read(file)
        let refreshed = try store.importArc(changed, selectedSpaces: selected, includeFavorites: true)
        expect(refreshed.added == 1 && refreshed.conflicts.count == 1, "refresh adds new IDs and preserves conflicting edits")
        expect(store.bookmark(store.arcMigration.records["item:pin"]!.targetID)?.title == "Edited in Safari", "source update never overwrites local edit")
        store.removeFolder(nestedID)
        let missing = try store.importArc(changed, selectedSpaces: selected, includeFavorites: true)
        expect(missing.added == 0 && !missing.conflicts.isEmpty && store.folder(nestedID) == nil, "deleted destination not resurrected")

        // Resume intent survives a native restart; no duplicate create token is generated.
        try apply(snapshot(), store)
        commands.removeAll()
        store.restoreArcTabs(destinations: ["Default": .init(instance: "safari", windowID: 10)])
        expect(commands.count == 1 && commands[0]["action"] as? String == "migrationCreate", "one-at-a-time restoration")
        let request = commands[0]["requestId"] as! String
        store.pauseArcRestore()
        let resumed = TabStore(stateURL: state)
        try apply(snapshot(), resumed)
        var resumeCommands: [[String: Any]] = []; resumed.sendCommand = { resumeCommands.append($0) }
        resumed.restoreArcTabs(destinations: [:])
        expect(resumeCommands.first?["requestId"] as? String == request, "restart retries the same durable intent")
        let liveTab = BrowserTab(id: 51, windowId: 10, index: 0, title: "Page", url: "https://example.com/same", active: false, pinned: false, audible: false, muted: false, loading: false)
        try apply(snapshot([liveTab]), resumed)
        _ = resumed.handleMessage(type: "migrationCreated", payload: Data(), object: ["instance": "wrong", "requestId": request, "tabId": 51])
        expect(resumed.arcMigration.tabs.first?.status == .sending, "wrong-profile acknowledgement ignored")
        resumed.pauseArcRestore()
        _ = resumed.handleMessage(type: "migrationCreated", payload: Data(), object: ["instance": "safari", "requestId": request, "tabId": 51])
        expect(resumed.arcMigration.tabs.first?.status == .restored && resumed.spaceState.spaceID(for: .init(instance: "safari", tabId: 51)) == spaceID, "late acknowledgement assigned to original space after snapshot race")
        expect(resumed.arcPendingTabs.count == 1, "completed requests removed from queue")
        resumeCommands.removeAll()
        resumed.restoreArcTabs(destinations: ["Default": .init(instance: "safari", windowID: 10)])
        resumed.pauseArcRestore()
        expect(resumeCommands.first?["requestId"] as? String != request, "closed or completed tabs never reopened by resume")
        let secondRequest = resumeCommands.first!["requestId"] as! String
        _ = resumed.handleMessage(type: "migrationAttention", payload: Data(), object: ["instance": "safari", "requestId": secondRequest, "message": "uncertain"])
        expect(resumed.arcMigration.tabs.last?.status == .attention && resumed.arcPendingTabs.isEmpty, "ambiguous requests retained for manual review")
        try resumed.undoArcImport(receipt.id)
        expect(resumed.tab(for: .init(instance: "safari", tabId: 51)) != nil, "undo never closes live Safari tabs")
        expect(resumed.bookmarks.contains { $0.title == "Edited in Safari" } && resumed.spaces.contains { $0.id == spaceID }, "undo keeps edited objects and occupied spaces")

        // A clean undo removes the tree from its own space regardless of selected space.
        try write(fixture(), file)
        let cleanSource = try ArcImportReader.read(file)
        let clean = TabStore(stateURL: temp.appendingPathComponent("clean.json"))
        let cleanReceipt = try clean.importArc(cleanSource, selectedSpaces: selected, includeFavorites: true)
        try clean.undoArcImport(cleanReceipt.id)
        expect(clean.folders.isEmpty && clean.bookmarks.isEmpty && clean.spaces.count == 1, "clean undo removes only imported tree")
        expect(clean.arcPendingTabs.isEmpty && clean.arcMigration.tabs.allSatisfy { $0.status == .cancelled }, "undo cancels unstarted restoration")
        let privateStore = TabStore(stateURL: temp.appendingPathComponent("private.json"))
        _ = try privateStore.importArc(cleanSource, selectedSpaces: selected, includeFavorites: false)
        try apply(snapshot(privateWindow: true), privateStore)
        var privateCommands: [[String: Any]] = []; privateStore.sendCommand = { privateCommands.append($0) }
        privateStore.restoreArcTabs(destinations: ["Default": .init(instance: "safari", windowID: 10)])
        expect(privateCommands.isEmpty && !privateStore.arcRestoreRunning, "private destination rejected")

        // Invalid files fail closed; unknown content stays accounted for and visible.
        var invalid = fixture()
        func modifyItems(_ object: inout [String: Any], _ change: (inout [Any]) -> Void) {
            var sidebar = object["sidebar"] as! [String: Any], containers = sidebar["containers"] as! [[String: Any]]
            var items = containers[1]["items"] as! [Any]; change(&items); containers[1]["items"] = items
            sidebar["containers"] = containers; object["sidebar"] = sidebar
        }
        modifyItems(&invalid) { list in list.append("odd") }
        do { _ = try ArcImportReader.parse(JSONSerialization.data(withJSONObject: invalid), sourceURL: file); fatalError("malformed dictionary accepted") } catch { checks += 1 }
        invalid = fixture()
        modifyItems(&invalid) { list in
            for i in stride(from: 1, to: list.count, by: 2) {
                var item = list[i] as! [String: Any]
                if item["id"] as? String == "n" { item["childrenIds"] = ["f"]; list[i] = item }
            }
        }
        do { _ = try ArcImportReader.parse(JSONSerialization.data(withJSONObject: invalid), sourceURL: file); fatalError("cycle accepted") } catch { checks += 1 }
        invalid = fixture()
        modifyItems(&invalid) { list in
            for i in stride(from: 1, to: list.count, by: 2) {
                if (list[i] as! [String: Any])["id"] as? String == "pin" { list[i] = item("pin", "tab", url: "javascript:alert(1)") }
                if (list[i] as! [String: Any])["id"] as? String == "a" { list[i] = item("a", "easel") }
            }
        }
        let unsupported = try ArcImportReader.parse(JSONSerialization.data(withJSONObject: invalid), sourceURL: file)
        expect(unsupported.entries.filter { $0.issue != nil }.count == 2 && unsupported.count(.unsupported) == 1, "unsafe links and Arc-only data explicitly accounted for")
        modifyItems(&invalid) { list in list.append(contentsOf: ["orphan", item("orphan", "tab")]) }
        let orphaned = try ArcImportReader.parse(JSONSerialization.data(withJSONObject: invalid), sourceURL: file)
        expect(orphaned.warnings.contains { $0.contains("unreferenced") } && !orphaned.entries.contains { $0.id == "item:orphan" }, "unreferenced records reported, not imported")
        var bulk = fixture()
        modifyItems(&bulk) { list in
            for i in stride(from: 1, to: list.count, by: 2) {
                var node = list[i] as! [String: Any]
                if node["id"] as? String == "p" {
                    node["childrenIds"] = (node["childrenIds"] as! [String]) + (0..<400).map { "bulk-folder-\($0)" }
                    list[i] = node
                }
            }
            for f in 0..<400 {
                let id = "bulk-folder-\(f)", children = (0..<3).map { "bulk-tab-\(f)-\($0)" }
                list.append(contentsOf: [id, item(id, "list", children: children)])
                for child in children { list.append(contentsOf: [child, item(child, "tab")]) }
            }
        }
        let bulkFile = temp.appendingPathComponent("bulk.json"); try write(bulk, bulkFile)
        let bulkSource = try ArcImportReader.read(bulkFile)
        let bulkStore = TabStore(stateURL: temp.appendingPathComponent("bulk-state.json"))
        _ = try bulkStore.importArc(bulkSource, selectedSpaces: selected, includeFavorites: true)
        expect(bulkStore.folders.count == 402 && bulkStore.bookmarks.count == 1206, "large source hierarchy imported without dropping duplicate URLs")
        let bulkRepeat = try bulkStore.importArc(bulkSource, selectedSpaces: selected, includeFavorites: true)
        expect(bulkRepeat.added == 0 && bulkRepeat.conflicts.isEmpty, "large source repeat remains idempotent")
        let blocked = temp.appendingPathComponent("blocked.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        let blockedStore = TabStore(stateURL: blocked)
        do { _ = try blockedStore.importArc(cleanSource, selectedSpaces: selected, includeFavorites: true); fatalError("failed persistence accepted") } catch { checks += 1 }
        expect(blockedStore.spaces.count == 1 && blockedStore.bookmarks.isEmpty && blockedStore.arcMigration.records.isEmpty, "failed persistence rolls back the whole in-memory transaction")
        let deletionFile = temp.appendingPathComponent("deletion-source.json")
        try write(fixture(), deletionFile)
        let deletionSource = try ArcImportReader.read(deletionFile)
        let deletionState = temp.appendingPathComponent("deletion-state.json")
        let deleting = TabStore(stateURL: deletionState)
        _ = try deleting.importArc(deletionSource, selectedSpaces: selected, includeFavorites: true)
        deleting.sendCommand = { _ in }
        try apply(snapshot(), deleting)
        deleting.restoreArcTabs(destinations: ["Default": .init(instance: "safari", windowID: 10)])
        let sending = deleting.arcMigration.tabs.first { $0.status == .sending }!
        deleting.deleteSpace(sending.spaceID, deleteContents: true)
        expect(!deleting.arcRestoreRunning && !deleting.arcPendingTabs.contains { $0.spaceID == sending.spaceID }, "space deletion pauses in-flight restore and cancels its queued tabs")
        deleting.save()
        let deletionLoaded = TabStore(stateURL: deletionState)
        var deletionCommands: [[String: Any]] = []
        deletionLoaded.sendCommand = { deletionCommands.append($0) }
        _ = deletionLoaded.handleMessage(type: "migrationCreated", payload: Data(), object: ["instance": "safari", "requestId": sending.requestID, "tabId": 909])
        expect(deletionCommands.last?["tabIds"] as? [Int] == [909], "late restore acknowledgement closes deleted-space tab after app restart")
        expect(!deletionLoaded.spaces.contains { $0.id == sending.spaceID }, "late restore cannot resurrect deleted space")
        print("Passed \(checks) Arc migration checks.")
    }
}
