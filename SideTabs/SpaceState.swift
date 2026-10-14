import Foundation

struct BrowserSpace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "Personal"
    var icon = "circle.fill"
    var theme = "blue"

    static let icons = ["circle.fill", "house.fill", "briefcase.fill", "star.fill", "book.fill", "heart.fill", "leaf.fill", "globe"]
    static let themes = ["blue", "purple", "pink", "orange", "green", "gray"]
}

/// Sidebar organization only: Safari retains its tabs, cookies, and profiles.
struct SpaceState: Codable, Equatable {
    struct Membership: Codable, Equatable {
        var key: TabKey
        var spaceID: UUID
        var url: String?
        var windowIndex: Int
        var privateWindow: Bool
        var profile: String?
    }

    var spaces: [BrowserSpace]
    var selectedID: UUID
    var memberships: [Membership] = []

    init() {
        let initial = BrowserSpace()
        spaces = [initial]
        selectedID = initial.id
    }

    var selected: BrowserSpace { spaces.first { $0.id == selectedID } ?? spaces[0] }

    mutating func normalize() {
        if spaces.isEmpty { spaces = [BrowserSpace()] }
        if !spaces.contains(where: { $0.id == selectedID }) { selectedID = spaces[0].id }
        for index in memberships.indices where !spaces.contains(where: { $0.id == memberships[index].spaceID }) {
            memberships[index].spaceID = spaces[0].id
        }
    }

    func spaceID(for key: TabKey) -> UUID? {
        memberships.first { $0.key == key }?.spaceID
    }

    mutating func assign(_ key: TabKey, to id: UUID) {
        guard spaces.contains(where: { $0.id == id }), let index = memberships.firstIndex(where: { $0.key == key }) else { return }
        memberships[index].spaceID = id
    }

    /// Existing tab IDs win. After Safari restarts, consume matching URLs one at a
    /// time, preserving duplicate tabs in distinct spaces rather than collapsing them.
    mutating func reconcile(_ snapshot: Snapshot, liveInstances: Set<String>) {
        let old = memberships
        for (windowIndex, window) in snapshot.windows.enumerated() {
            for tab in window.tabs {
                let key = TabKey(instance: snapshot.instance, tabId: tab.id)
                if let index = memberships.firstIndex(where: { $0.key == key }) {
                    memberships[index].url = tab.url
                    memberships[index].windowIndex = windowIndex
                    memberships[index].privateWindow = window.incognito
                    memberships[index].profile = snapshot.profile
                    continue
                }
                var owner = selectedID
                if let url = tab.url, let restored = memberships.firstIndex(where: {
                    !liveInstances.contains($0.key.instance) && $0.url == url &&
                    $0.windowIndex == windowIndex && $0.privateWindow == window.incognito && $0.profile == snapshot.profile
                }) {
                    owner = memberships.remove(at: restored).spaceID
                }
                memberships.append(Membership(key: key, spaceID: owner, url: tab.url,
                    windowIndex: windowIndex, privateWindow: window.incognito, profile: snapshot.profile))
            }
        }
        let liveKeys = Set(snapshot.windows.flatMap { $0.tabs.map { TabKey(instance: snapshot.instance, tabId: $0.id) } })
        memberships.removeAll { $0.key.instance == snapshot.instance && !liveKeys.contains($0.key) }
        // Missing tabs in a live instance are closed, not candidates for URL restoration.
        // Dead instances are retained until their restored tabs arrive in later snapshots.
        if old != memberships { normalize() }
    }

    mutating func remove(_ id: UUID) -> UUID? {
        guard spaces.count > 1, spaces.contains(where: { $0.id == id }) else { return nil }
        spaces.removeAll { $0.id == id }
        let destination = spaces[0].id
        for index in memberships.indices where memberships[index].spaceID == id {
            memberships[index].spaceID = destination
        }
        if selectedID == id { selectedID = destination }
        return destination
    }

    /// Never add private browsing URLs to the saved space state.
    var persistentCopy: SpaceState {
        var copy = self
        copy.memberships.removeAll { $0.privateWindow }
        return copy
    }
}
