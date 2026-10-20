import Foundation

struct BrowserSpace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "Personal"
    var icon = "circle.fill"
    var theme = "blue"
    var arcProfileID: String? = nil
    /// nil retains the existing SF Symbol; optional for older saved spaces.
    var emoji: String? = nil

    static func normalizedEmoji(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = value.unicodeScalars
        let keycap = scalars.contains(where: { $0.value == 0x20E3 }) &&
            scalars.first.map { "#*0123456789".unicodeScalars.contains($0) } == true
        guard value.count == 1,
              keycap || scalars.contains(where: { $0.properties.isEmoji && $0.value > 0x7F }) else { return nil }
        return value
    }

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
        var lastUsedAt: Date? = nil
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
    mutating func reconcile(_ snapshot: Snapshot, liveInstances: Set<String>, now: Date = Date(), recentlyUsed: Set<TabKey>? = nil) {
        let old = memberships
        for (windowIndex, window) in snapshot.windows.enumerated() {
            for tab in window.tabs {
                let key = TabKey(instance: snapshot.instance, tabId: tab.id)
                if let index = memberships.firstIndex(where: { $0.key == key }) {
                    let inUse = tab.active || tab.audible || tab.loading || tab.pinned
                    let wasInUse = recentlyUsed?.contains(key) ?? false
                    if memberships[index].lastUsedAt == nil || memberships[index].url != tab.url || inUse != wasInUse ||
                       (inUse && now.timeIntervalSince(memberships[index].lastUsedAt ?? now) >= 60) {
                        memberships[index].lastUsedAt = now
                    }
                    memberships[index].url = tab.url
                    memberships[index].windowIndex = windowIndex
                    memberships[index].privateWindow = window.incognito
                    memberships[index].profile = snapshot.profile
                    continue
                }
                var owner = selectedID
                var lastUsedAt = now
                if let url = tab.url, let restored = memberships.firstIndex(where: {
                    !liveInstances.contains($0.key.instance) && $0.url == url &&
                    $0.windowIndex == windowIndex && $0.privateWindow == window.incognito && $0.profile == snapshot.profile
                }) {
                    let restoredMember = memberships.remove(at: restored)
                    owner = restoredMember.spaceID
                    if !tab.active && !tab.audible && !tab.loading && !tab.pinned {
                        lastUsedAt = restoredMember.lastUsedAt ?? now
                    }
                }
                memberships.append(Membership(key: key, spaceID: owner, url: tab.url,
                    windowIndex: windowIndex, privateWindow: window.incognito, profile: snapshot.profile, lastUsedAt: lastUsedAt))
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

    /// Destination is the final index, after removing the moving space.
    @discardableResult mutating func move(_ id: UUID, to destination: Int) -> Bool {
        guard let source = spaces.firstIndex(where: { $0.id == id }),
              spaces.indices.contains(destination), source != destination else { return false }
        spaces.insert(spaces.remove(at: source), at: destination)
        return true
    }

    /// Never add private browsing URLs to the saved space state.
    var persistentCopy: SpaceState {
        var copy = self
        copy.memberships.removeAll { $0.privateWindow }
        return copy
    }
}

/// Transient icon-strip drag geometry. Preview only; the store commits on release.
struct SpaceIconDrag {
    static let size: CGFloat = 28
    static let spacing: CGFloat = 4
    static let pitch = size + spacing
    let id: UUID
    private(set) var order: [UUID]
    private(set) var location: CGPoint
    private let grabOffset: CGFloat

    init?(id: UUID, order: [UUID], start: CGPoint, contentX: CGFloat) {
        guard start.x.isFinite, start.y.isFinite, contentX.isFinite,
              let index = order.firstIndex(of: id) else { return nil }
        self.id = id; self.order = order; self.location = start
        grabOffset = min(max(start.x - contentX - CGFloat(index) * Self.pitch, 0), Self.size)
    }

    mutating func update(at point: CGPoint, contentX: CGFloat) {
        guard point.x.isFinite, point.y.isFinite, contentX.isFinite else { return }
        location = point
        let position = ((point.x - grabOffset - contentX) / Self.pitch).rounded()
        let destination = Int(min(max(position, 0), CGFloat(order.count - 1)))
        guard let source = order.firstIndex(of: id), source != destination else { return }
        order.insert(order.remove(at: source), at: destination)
    }

    func canDrop(in width: CGFloat) -> Bool {
        width > 0 && location.x >= -14 && location.x <= width + 14 &&
        location.y >= -14 && location.y <= Self.size + 14
    }

    var ghostX: CGFloat { location.x - grabOffset }

    /// Reveal one more icon at a time while held near a clipped edge.
    func scrollTarget(width: CGFloat, contentX: CGFloat) -> (id: UUID, towardEnd: Bool)? {
        guard width > 0, contentX.isFinite, canDrop(in: width) else { return nil }
        let contentWidth = CGFloat(order.count) * Self.pitch - Self.spacing
        if location.x >= width - 16, contentX + contentWidth > width + 0.5 {
            let index = Int(min(max(((width - contentX) / Self.pitch).rounded(.down), 0), CGFloat(order.count - 1)))
            return (order[index], true)
        }
        if location.x <= 16, contentX < -0.5 {
            let index = Int(min(max((-contentX / Self.pitch).rounded(.down) - 1, 0), CGFloat(order.count - 1)))
            return (order[index], false)
        }
        return nil
    }
}
