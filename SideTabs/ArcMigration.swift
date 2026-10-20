import Foundation
import CryptoKit

/// Arc is read-only. Only this active sidebar is traversed; sync caches are not imports.
struct ArcImportSnapshot {
    var sourceURL: URL
    var data: Data
    var hash: String
    var savedAt: Date?
    var spaces: [ArcImportSpace]
    var entries: [ArcImportEntry]
    var warnings: [String]
    var containerCount: Int
    var sourceItemCount: Int
    var profiles: [String] { Array(Set(spaces.map(\.profileID) + entries.map(\.profileID))).sorted() }
    var folders: Int { entries.filter { $0.kind == .folder }.count }
    func count(_ kind: ArcImportEntry.Kind) -> Int { entries.filter { $0.kind == kind }.count }
}

struct ArcImportSpace: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var profileID: String
    var icon: String
    var theme: String
    var originalIcon: String?
    var order = 0
}

struct ArcImportEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case folder, pin, favorite, tab, unsupported }
    var id: String
    var spaceID: String?
    var profileID: String
    var parentID: String?
    var title: String
    var url: String?
    var kind: Kind
    var depth: Int
    var splitID: String?
    var issue: String?
    var order = 0
    var signature: String { ArcImportReader.signature(self) }
}

struct ArcImportFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct ArcImportReader {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")
    }
    static func signature<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return hash((try? encoder.encode(value)) ?? Data())
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func read(_ url: URL = defaultURL) throws -> ArcImportSnapshot {
        for _ in 0..<3 {
            let first = try Data(contentsOf: url)
            let second = try Data(contentsOf: url)
            if first == second {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return try parse(first, sourceURL: url, savedAt: date)
            }
        }
        throw ArcImportFailure(message: "Arc is saving its sidebar. Wait a moment and refresh the preview.")
    }
    /// Swift encodes dictionaries with non-string keys as alternating key/value arrays.
    static func pairs(_ value: Any?) throws -> [(Any, Any)] {
        if let dict = value as? [String: Any] { return dict.keys.sorted().map { ($0, dict[$0]!) } }
        guard let array = value as? [Any], array.count.isMultiple(of: 2) else {
            throw ArcImportFailure(message: "Arc's sidebar format is not recognized (invalid dictionary).")
        }
        return stride(from: 0, to: array.count, by: 2).map { (array[$0], array[$0 + 1]) }
    }
    static func profile(_ value: Any?) -> String {
        let object = value as? [String: Any] ?? [:]
        if object["default"] != nil { return "Default" }
        if let custom = object["custom"] as? [String: Any], let details = custom["_0"] as? [String: Any],
           let basename = details["directoryBasename"] as? String { return basename }
        let encoded = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return "Profile " + hash(encoded).prefix(8)
    }
    static func parse(_ data: Data, sourceURL: URL, savedAt: Date? = nil) throws -> ArcImportSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] is NSNumber,
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [[String: Any]],
              let active = containers.first(where: { $0["spaces"] != nil && $0["items"] != nil }) else {
            throw ArcImportFailure(message: "This file has no supported active Arc sidebar. No changes were made.")
        }
        var items: [String: [String: Any]] = [:]
        for (key, value) in try pairs(active["items"]) {
            guard let id = key as? String, let item = value as? [String: Any], item["id"] as? String == id,
                  items[id] == nil else { throw ArcImportFailure(message: "Arc contains duplicate or invalid item IDs.") }
            items[id] = item
        }
        var spaces: [ArcImportSpace] = []
        var entries: [ArcImportEntry] = []
        var warnings: [String] = []
        var visited = Set<String>()
        var containerCount = 0
        func walk(_ id: String, space: String?, profileID: String, parent: String?, kind: ArcImportEntry.Kind, depth: Int, split: String? = nil, position: Int = 0, chain: Set<String> = []) throws {
            guard depth < 256, !chain.contains(id), visited.insert(id).inserted else {
                throw ArcImportFailure(message: "Arc's active sidebar contains a cycle or a repeated item reference. Review the source before importing.")
            }
            guard let item = items[id], let payload = item["data"] as? [String: Any], payload.count == 1,
                  let variant = payload.keys.first, let children = item["childrenIds"] as? [String] else {
                throw ArcImportFailure(message: "Arc's active sidebar contains an invalid item or missing reference.")
            }
            let itemID = "item:" + id
            let name = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var nextParent = parent
            var nextDepth = depth
            var nextSplit = split
            switch variant {
            case "itemContainer": containerCount += 1
            case "list":
                entries.append(.init(id: itemID, spaceID: space, profileID: profileID, parentID: parent,
                    title: name?.isEmpty == false ? name! : "Untitled Folder", kind: .folder, depth: depth, splitID: split, order: position))
                nextParent = itemID
                nextDepth += 1
            case "splitView":
                nextSplit = itemID
                warnings.append("Split view will become adjacent individual tabs (\(children.count) items).")
            case "tab":
                let tab = payload[variant] as? [String: Any] ?? [:]
                let url = tab["savedURL"] as? String
                let fallback = (tab["savedTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url ?? "Untitled Tab"
                let scheme = url.flatMap { URL(string: $0)?.scheme?.lowercased() }
                let supported = scheme == "https" || scheme == "http" || url == "about:blank"
                entries.append(.init(id: itemID, spaceID: space, profileID: profileID, parentID: parent,
                    title: name?.isEmpty == false ? name! : fallback, url: url, kind: kind, depth: depth, splitID: split,
                    issue: supported ? nil : "Requires manual handling: \(scheme ?? "missing URL") links cannot be restored automatically.", order: position))
            default:
                let details = payload[variant] as? [String: Any]
                entries.append(.init(id: itemID, spaceID: space, profileID: profileID, parentID: parent,
                    title: name ?? (details?["title"] as? String) ?? variant, kind: .unsupported, depth: depth, splitID: split,
                    issue: "Arc \(variant) has no Safari equivalent. Its original data is retained in the import snapshot.", order: position))
            }
            var chain = chain; chain.insert(id)
            for (position, child) in children.enumerated() {
                try walk(child, space: space, profileID: profileID, parent: nextParent, kind: kind, depth: nextDepth, split: nextSplit, position: position, chain: chain)
            }
        }
        var spaceIDs = Set<String>()
        for (key, value) in try pairs(active["spaces"]) {
            guard let id = key as? String, let raw = value as? [String: Any], raw["id"] as? String == id,
                  spaceIDs.insert(id).inserted else { throw ArcImportFailure(message: "Arc contains invalid or duplicate spaces.") }
            let profileID = profile(raw["profile"])
            let custom = raw["customInfo"] as? [String: Any] ?? [:]
            let emoji = (custom["iconType"] as? [String: Any])?["emoji_v2"] as? String
            let theme = closestTheme(custom["windowTheme"] as? [String: Any])
            spaces.append(.init(id: "space:" + id, name: raw["title"] as? String ?? "Untitled Space",
                                profileID: profileID, icon: emoji == "📘" ? "book.fill" : "globe", theme: theme, originalIcon: emoji, order: spaces.count))
            var roots: [String: String] = [:]
            for (key, value) in try pairs(raw["newContainerIDs"] ?? raw["containerIDs"]) {
                let name = (key as? [String: Any])?.keys.first ?? (key as? String)
                guard let name, name == "pinned" || name == "unpinned", let rootID = value as? String, roots[name] == nil else {
                    throw ArcImportFailure(message: "An Arc space has an unsupported tab container. No changes were made.")
                }
                roots[name] = rootID
            }
            for name in ["pinned", "unpinned"] {
                guard let rootID = roots[name] else { throw ArcImportFailure(message: "An Arc space is missing its \(name) container.") }
                try walk(rootID, space: "space:" + id, profileID: profileID, parent: nil, kind: name == "pinned" ? .pin : .tab, depth: 0)
            }
        }
        for (key, value) in try pairs(active["topAppsContainerIDs"]) {
            guard let id = value as? String else { throw ArcImportFailure(message: "Arc has an invalid Favorites container.") }
            try walk(id, space: nil, profileID: profile(key), parent: nil, kind: .favorite, depth: 0)
        }
        guard !spaces.isEmpty else { throw ArcImportFailure(message: "Arc has no active spaces to import.") }
        let unreachable = Set(items.keys).subtracting(visited)
        if !unreachable.isEmpty { warnings.append("\(unreachable.count) unreferenced records are excluded from the active sidebar. Original records remain in the snapshot.") }
        if Set(spaces.map(\.profileID)).count > 1 {
            warnings.append("Arc profiles have separate Favorites. Side Tabs will keep those sets separate. Spaces do not isolate Safari cookies or logins; choose the appropriate Safari window for each profile when restoring tabs.")
        }
        warnings.append("This preview uses Arc's saved sidebar, not private windows, archived tabs, or unsaved browser state. Refresh after Arc finishes saving if you recently changed tabs.")
        return .init(sourceURL: sourceURL, data: data, hash: hash(data), savedAt: savedAt, spaces: spaces,
                     entries: entries, warnings: warnings, containerCount: containerCount, sourceItemCount: items.count)
    }
    private static func closestTheme(_ theme: [String: Any]?) -> String {
        guard let palette = theme?["primaryColorPalette"] as? [String: Any], let color = palette["midTone"] as? [String: Any],
              let r = color["red"] as? Double, let g = color["green"] as? Double, let b = color["blue"] as? Double else { return "blue" }
        let colors: [(String, Double, Double, Double)] = [("blue",0.3,0.5,0.8),("purple",0.6,0.4,0.8),("pink",0.85,0.5,0.6),("orange",0.85,0.65,0.4),("green",0.4,0.7,0.4),("gray",0.6,0.6,0.6)]
        return colors.min { a, c in
            pow(r-a.1,2)+pow(g-a.2,2)+pow(b-a.3,2) < pow(r-c.1,2)+pow(g-c.2,2)+pow(b-c.3,2)
        }!.0
    }
}

struct ArcImportDestination: Codable, Equatable, Hashable {
    var instance: String
    var windowID: Int
}
struct ArcImportRecord: Codable {
    enum Kind: String, Codable { case space, folder, bookmark, tab }
    var sourceID: String
    var targetID: UUID
    var kind: Kind
    var sourceSignature: String
    var targetSignature: String
    var batchID: UUID
}
struct ArcTabRestore: Codable, Identifiable {
    enum Status: String, Codable { case pending, sending, restored, attention, cancelled }
    var id: String
    var requestID: String = UUID().uuidString
    var title: String
    var url: String
    var spaceID: UUID
    var profileID: String
    var batchID: UUID
    var status: Status = .pending
    var destination: ArcImportDestination?
    var key: TabKey?
    var message: String?
    var deleteOnArrival: Bool? = nil
}
struct ArcImportReceipt: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var snapshotHash: String
    var added: Int
    var retained: Int
    var conflicts: [String]
    var attention: [ArcImportEntry]
    var backupPath: String
    var undone = false
}
struct ArcMigrationState: Codable {
    var records: [String: ArcImportRecord] = [:]
    var tabs: [ArcTabRestore] = []
    var receipts: [ArcImportReceipt] = []
}
enum ArcImportDisposition: String {
    case add = "New", retained = "Already imported", conflict = "Review needed", attention = "Manual handling"
}
