import Foundation

/// A Safari tab as reported by background.js.
struct BrowserTab: Codable, Identifiable, Hashable {
    let id: Int
    let windowId: Int
    var index: Int
    var title: String?
    var url: String?
    var active: Bool
    var pinned: Bool
    var audible: Bool
    var muted: Bool
    var loading: Bool
    var favIconUrl: String?

    var host: String? {
        url.flatMap { URL(string: $0)?.host() }
    }
}

struct BrowserWindow: Codable, Identifiable, Hashable {
    let id: Int
    var focused: Bool
    var incognito: Bool
    var tabs: [BrowserTab]
}

/// Everything one background page (one Safari profile) knows about its windows.
struct Snapshot: Codable {
    let instance: String
    let seq: Int
    let focusedWindowId: Int?
    let lastFocusedWindowId: Int?
    let focusChangedAt: Double
    /// When the extension started building this snapshot (`Date.now()`, milliseconds since 1970).
    /// Nil from an extension page that doesn't send it.
    let startedAt: Double?
    var windows: [BrowserWindow]
    var profile: String?
}

/// Tab ids are only unique within one background page instance.
struct TabKey: Hashable, Codable {
    let instance: String
    let tabId: Int
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var faviconURL: String?
}

/// A tab name the user picked, plus the URL it had so it can be matched up again
/// after Safari restarts and hands out new tab ids.
struct CustomName: Codable, Hashable {
    var name: String
    var url: String?
}

enum RenameTarget: Hashable {
    case tab(TabKey)
    case bookmark(UUID)
    /// A folder in Pinned (#76).
    case folder(UUID)
}

extension String {
    /// URL used to decide whether a bookmark is already open: ignores the fragment
    /// and a trailing slash.
    var comparableURL: String {
        guard var components = URLComponents(string: self) else { return self }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? self
    }
}

extension Snapshot {
    /// Whether `other` shows the same: the same windows and tabs, focus and profile. `seq` and `startedAt` only say
    /// when a snapshot was taken (#81).
    func hasSameContent(as other: Snapshot) -> Bool {
        instance == other.instance && windows == other.windows && focusedWindowId == other.focusedWindowId
            && lastFocusedWindowId == other.lastFocusedWindowId && focusChangedAt == other.focusChangedAt
            && profile == other.profile
    }

    /// The snapshot `changes` stand for: this one, the copy's state numbered `changes.base`, with them applied (#81).
    /// Nil when they're counted from another state, or name a window or tab neither has: then only a full snapshot
    /// can say what the copy's windows are.
    func applying(_ changes: SnapshotChanges) -> Snapshot? {
        guard changes.instance == instance, changes.base == seq else { return nil }
        var oldWindows: [Int: BrowserWindow] = [:]
        var oldTabs: [Int: BrowserTab] = [:]
        for window in windows {
            oldWindows[window.id] = window
            for tab in window.tabs {
                oldTabs[tab.id] = tab
            }
        }
        var newTabs: [Int: BrowserTab] = [:]
        for tab in changes.tabs ?? [] {
            newTabs[tab.id] = tab
        }
        var changedWindows: [Int: SnapshotChanges.WindowChange] = [:]
        for window in changes.windows ?? [] {
            changedWindows[window.id] = window
        }
        var result: [BrowserWindow] = []
        for windowId in changes.windowIds ?? windows.map(\.id) {
            let old = oldWindows[windowId]
            let change = changedWindows[windowId]
            guard let tabIds = change?.tabIds ?? old?.tabs.map(\.id),
                  let focused = change?.focused ?? old?.focused,
                  let incognito = change?.incognito ?? old?.incognito else { return nil }
            var tabs: [BrowserTab] = []
            tabs.reserveCapacity(tabIds.count)
            for (index, tabId) in tabIds.enumerated() {
                guard let tab = newTabs[tabId] ?? oldTabs[tabId] else { return nil }
                // Where a tab is comes from its window's list.
                tabs.append(BrowserTab(id: tab.id, windowId: windowId, index: index, title: tab.title, url: tab.url,
                                       active: tab.active, pinned: tab.pinned, audible: tab.audible, muted: tab.muted,
                                       loading: tab.loading, favIconUrl: tab.favIconUrl))
            }
            result.append(BrowserWindow(id: windowId, focused: focused, incognito: incognito, tabs: tabs))
        }
        let focus = changes.focus
        return Snapshot(
            instance: instance,
            seq: changes.seq,
            focusedWindowId: focus.map(\.focusedWindowId) ?? focusedWindowId,
            lastFocusedWindowId: focus.map(\.lastFocusedWindowId) ?? lastFocusedWindowId,
            focusChangedAt: focus?.focusChangedAt ?? focusChangedAt,
            startedAt: changes.startedAt,
            windows: result,
            profile: changes.profile ?? profile
        )
    }
}

/// What changed in one copy's windows since the state numbered `base`, which the app took before (#81). Each part
/// is nil when nothing in it changed. Built by `changesSince` in background.js.
struct SnapshotChanges: Codable {
    struct Focus: Codable {
        let focusedWindowId: Int?
        let lastFocusedWindowId: Int?
        let focusChangedAt: Double
    }

    /// A window that's new or changed: its tabs' ids in order when those changed (always for a new window).
    struct WindowChange: Codable {
        let id: Int
        let focused: Bool
        let incognito: Bool
        let tabIds: [Int]?
    }

    let instance: String
    let seq: Int
    let base: Int
    let startedAt: Double?
    let focus: Focus?
    /// The windows in order, when that changed.
    let windowIds: [Int]?
    let windows: [WindowChange]?
    /// Each new or changed tab, whole.
    let tabs: [BrowserTab]?
    /// Added by the extension's handler, as for every message.
    let profile: String?
}

/// A message from the extension, read from its JSON once (#81). A snapshot or changes, the large ones, are decoded
/// straight into their types; `object` then has only the fields the store reads about who sent it. Every other
/// message is small, and `object` has all of it.
struct ExtensionMessage {
    let type: String
    let object: [String: Any]
    let snapshot: Snapshot?
    let changes: SnapshotChanges?
    /// Why a snapshot or changes couldn't be decoded.
    let error: Error?

    private struct Head: Decodable {
        enum CodingKeys: String, CodingKey {
            case type, instance, profile, extensionPath
        }

        let type: String
        let instance: String?
        let profile: String?
        let extensionPath: String?
        var snapshot: Snapshot?
        var changes: SnapshotChanges?
        var error: Error?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            instance = try? container.decodeIfPresent(String.self, forKey: .instance)
            profile = try? container.decodeIfPresent(String.self, forKey: .profile)
            extensionPath = try? container.decodeIfPresent(String.self, forKey: .extensionPath)
            do {
                switch type {
                case "snapshot": snapshot = try Snapshot(from: decoder)
                case "changes": changes = try SnapshotChanges(from: decoder)
                default: break
                }
            } catch {
                self.error = error
            }
        }
    }

    static let stateTypes: Set<String> = ["snapshot", "changes"]

    init?(data: Data) {
        guard let head = try? JSONDecoder().decode(Head.self, from: data) else { return nil }
        type = head.type
        snapshot = head.snapshot
        changes = head.changes
        error = head.error
        if Self.stateTypes.contains(type) {
            var object: [String: Any] = ["type": type]
            object["instance"] = head.instance
            object["profile"] = head.profile
            object["extensionPath"] = head.extensionPath
            object["seq"] = head.snapshot?.seq ?? head.changes?.seq
            self.object = object
        } else {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            self.object = object
        }
    }
}
