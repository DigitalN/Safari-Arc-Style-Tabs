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
