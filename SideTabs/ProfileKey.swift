import Foundation

/// Which Safari profile something belongs to, as the extension sees it. Each profile runs its
/// own copy of the extension, and Safari sends that copy's messages with the profile's UUID
/// (`Snapshot.profile`). The default profile's copy sends none. The UUID stays the same across
/// reinstalls, extension reloads and Safari relaunches (#28).
nonisolated struct ProfileKey: Hashable, Codable, Sendable, CustomStringConvertible {
    /// "default", or the profile's UUID string as Safari sends it.
    let rawValue: String

    static let defaultProfile = ProfileKey(rawValue: "default")

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// From a snapshot's `profile` field.
    init(snapshotProfile: String?) {
        self.rawValue = snapshotProfile ?? "default"
    }

    var isDefault: Bool { self == .defaultProfile }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
