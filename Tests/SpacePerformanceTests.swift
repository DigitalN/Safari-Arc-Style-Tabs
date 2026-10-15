import AppKit
import Foundation

/// Synthetic library only. No Safari commands, network requests, or user state.
@main @MainActor struct SpacePerformanceTests {
    struct State: Encodable {
        var bookmarks: [Bookmark]
        var names: [String] = []
        var orphanNames: [String: String] = [:]
        var spaces: SpaceState
        var folders: FolderState
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sidetabs-performance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var spaces = SpaceState()
        spaces.spaces = (0..<20).map { BrowserSpace(name: "Space \($0)") }
        spaces.selectedID = spaces.spaces[0].id
        var bookmarks: [Bookmark] = []
        var folders = FolderState()
        var tabs: [BrowserTab] = []
        for (spaceIndex, space) in spaces.spaces.enumerated() {
            for folderIndex in 0..<20 {
                let folder = PinnedFolder(name: "Folder \(folderIndex)", spaceID: space.id)
                folders.folders.append(folder)
                folders.order.append(.folder(folder.id))
                for pin in 0..<3 {
                    let id = spaceIndex * 60 + folderIndex * 3 + pin + 1
                    let bookmark = Bookmark(title: "Pin \(id)", url: "https://example.com/\(id)", spaceID: space.id, folderID: folder.id)
                    bookmarks.append(bookmark)
                    folders.order.append(.bookmark(bookmark.id))
                    if pin == 0 {
                        tabs.append(BrowserTab(id: id, windowId: 10, index: tabs.count, title: bookmark.title,
                            url: bookmark.url, active: id == 1, pinned: false, audible: false, muted: false, loading: false))
                        spaces.memberships.append(.init(key: TabKey(instance: "benchmark", tabId: id),
                            spaceID: space.id, url: bookmark.url, windowIndex: 0, privateWindow: false, profile: nil))
                    }
                }
            }
        }
        let url = directory.appendingPathComponent("state.json")
        try JSONEncoder().encode(State(bookmarks: bookmarks, spaces: spaces, folders: folders)).write(to: url)
        let store = TabStore(stateURL: url)
        let snapshot = Snapshot(instance: "benchmark", seq: 1, focusedWindowId: 10, lastFocusedWindowId: 10,
            focusChangedAt: 0, windows: [BrowserWindow(id: 10, focused: true, incognito: false, tabs: tabs)])
        _ = store.handleMessage(type: "snapshot", payload: try JSONEncoder().encode(snapshot), object: [:])
        var timings: [Double] = []
        var checksum = 0
        // Match the data requests made by the sections, folder rows, pin rows, and menus.
        for _ in 0..<2 {
            for space in spaces.spaces {
                let start = ProcessInfo.processInfo.systemUptime
                store.selectSpace(space.id)
                let selection = store.currentWindow!
                checksum += store.favorites.count + store.displayedTabs(in: selection).count
                for entry in store.visiblePinnedEntries {
                    switch entry.item {
                    case .folder(let id):
                        checksum += store.pinnedChildren(of: id).count + store.folderPath(id).count
                    case .bookmark(let id):
                        if let bookmark = store.bookmark(id) {
                            checksum += store.openTab(for: bookmark) == nil ? 1 : 2
                        }
                    }
                }
                checksum += store.pinnedEntries(includeCollapsed: true).count
                timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
        }
        timings.sort()
        print("Synthetic library: \(bookmarks.count) pins, \(folders.folders.count) folders, \(tabs.count) live tabs, \(spaces.spaces.count) spaces")
        print(String(format: "Space selection + row data: median %.2f ms, p95 %.2f ms, max %.2f ms; checksum %d",
            timings[timings.count / 2], timings[Int(Double(timings.count - 1) * 0.95)], timings.last!, checksum))
        guard checksum == 15600 else { fatalError("Presentation changed: \(checksum)") }
    }
}
