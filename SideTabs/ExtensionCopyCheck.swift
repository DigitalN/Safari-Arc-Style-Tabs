import Foundation

/// Which copy of Side Tabs' extension Safari runs, and when to put this copy's in its place (#67).
///
/// `SFSafariApplication.dispatchMessage` only delivers to the extension inside the app that calls it. When
/// Safari runs another copy's extension (a build left in DerivedData, a copy in Downloads, the app on a mounted
/// disk image), every command from the sidebar fails with `SFErrorNoExtensionFound`: close, +, reload, mute,
/// reordering. Messages the other way still arrive, because the extension's handler reaches the app through a
/// named message port that any copy can reach, so the sidebar keeps showing the tabs.
///
/// The handler says where it is (`extensionPath`, in every message it passes on). It's a problem when that
/// isn't inside this app's bundle, or when a command fails with `SFErrorNoExtensionFound`, which also covers an
/// extension too old to say where it is. Then the app registers its own extension in place of the other copy's
/// (ExtensionRegistration), as `install.sh` does. If Safari still runs the other copy once it's had the time to
/// switch, the sidebar says where that copy is (`notice`) until this copy's extension talks to the app.
///
/// Times are on the Mac's awake clock, like TabStore's.
nonisolated struct ExtensionCopyCheck: Equatable, Sendable {
    /// What a message says about the copy of the extension that sent it.
    enum Sender: Equatable, Sendable {
        /// This app's own extension.
        case own
        /// Another copy's: the bundle it belongs to (see `bundle(ofExtension:)`).
        case other(String)
        /// An extension too old to say where it is.
        case unknown
    }

    /// Where Safari's copy is, for the notice: its app, or the extension on its own. Nil when that can't be
    /// told: an extension too old to say, and no other copy registered with macOS.
    struct OtherCopy: Equatable, Sendable {
        let path: String?
    }

    /// How long Safari has, after the app registers its own extension, to start it in place of the other
    /// copy's before the sidebar shows the notice. On 2026-11-12 it took about a second, and each copy
    /// sends a heartbeat every 5 s.
    static let switchTime: TimeInterval = 10
    /// How long after a repair that didn't work the next one may run: this, then twice as long each time
    /// after, up to `longestWait`, until this app's extension talks to it.
    static let firstWait: TimeInterval = 60
    static let longestWait: TimeInterval = 30 * 60
    /// A copy of the extension heard from within this is still running: the allowance #31 gives a heartbeat.
    static let runningWithin: TimeInterval = 30

    /// The app's own bundle.
    let appPath: String

    /// What the sidebar shows: Safari runs another copy, and registering this one's didn't make it switch.
    private(set) var notice: OtherCopy?
    /// A repair is running, or has been asked for.
    private(set) var repairing = false
    /// The last copy heard from, and when.
    private(set) var lastSender: Sender?
    private var lastHeardAt: TimeInterval?
    /// The other copy last heard from.
    private var otherPath: String?
    /// The other copies the last repair found registered with macOS.
    private var foundCopies: [String] = []
    /// When the last repair finished, and how many have run since this app's extension last talked to it.
    private var repairedAt: TimeInterval?
    private var repairsWithoutSuccess = 0

    init(appPath: String) {
        self.appPath = appPath
    }

    /// The app can't put its extension in place of another from a path macOS made up for it: a quarantined
    /// app opened where it was downloaded runs from a random, read-only place (App Translocation), and its
    /// extension there would be gone as soon as it quits.
    var canRepair: Bool {
        !appPath.contains("/AppTranslocation/")
    }

    /// Notes a message from the extension: `extensionPath` is where its handler is, nil from one too old to
    /// say. True when a repair should start now (then `repairStarted`, and `repairFinished` once it's done).
    mutating func heard(extensionPath: String?, at now: TimeInterval) -> Bool {
        let sender = Self.sender(extensionPath: extensionPath, appPath: appPath)
        lastSender = sender
        lastHeardAt = now
        switch sender {
        case .own:
            // The right copy is talking: whatever was wrong is over.
            notice = nil
            repairsWithoutSuccess = 0
            return false
        case .other(let path):
            otherPath = path
            return problem(at: now)
        case .unknown:
            // An old extension on its own isn't a problem: after an update, Safari runs the old one from the
            // same place until it reloads it. Commands to it fail only if it's another copy's.
            return false
        }
    }

    /// A command failed with `SFErrorNoExtensionFound`: Safari runs no extension of this app's. True when a
    /// repair should start now.
    mutating func commandFoundNoExtension(at now: TimeInterval) -> Bool {
        problem(at: now)
    }

    mutating func repairStarted() {
        repairing = true
    }

    /// The repair is done. `otherCopies` are the other copies it found registered (and unregistered).
    mutating func repairFinished(otherCopies: [String], at now: TimeInterval) {
        repairing = false
        repairedAt = now
        repairsWithoutSuccess += 1
        foundCopies = otherCopies
    }

    /// How long after the last repair the next may run.
    var waitBeforeNextRepair: TimeInterval {
        guard repairsWithoutSuccess > 0 else { return 0 }
        let doublings = Double(min(repairsWithoutSuccess - 1, 16))
        return min(Self.firstWait * pow(2, doublings), Self.longestWait)
    }

    /// Something says Safari runs another copy. Shows the notice if a repair was given its time and another
    /// copy is still talking; says whether to repair again.
    private mutating func problem(at now: TimeInterval) -> Bool {
        guard !repairing else { return false }
        let repairHadItsTime = repairedAt.map { now - $0 >= Self.switchTime } ?? !canRepair
        if repairHadItsTime, let copy = runningOtherCopy(at: now) {
            notice = copy
        }
        guard canRepair else { return false }
        if let repairedAt, now - repairedAt < waitBeforeNextRepair {
            return false
        }
        return true
    }

    /// The copy that isn't this app's and is talking to it, if one is: the last one heard from, lately.
    private func runningOtherCopy(at now: TimeInterval) -> OtherCopy? {
        guard let lastSender, let lastHeardAt, now - lastHeardAt < Self.runningWithin else { return nil }
        switch lastSender {
        case .own:
            return nil
        case .other(let path):
            return OtherCopy(path: path)
        case .unknown:
            // An extension too old to say: the copy registered with macOS, if the repair found one.
            return OtherCopy(path: otherPath ?? foundCopies.first)
        }
    }

    // MARK: - Paths

    /// What a message's `extensionPath` says about the copy that sent it, for an app at `appPath`.
    static func sender(extensionPath: String?, appPath: String) -> Sender {
        guard let extensionPath, !extensionPath.isEmpty else { return .unknown }
        return isInside(extensionPath, bundle: appPath) ? .own : .other(bundle(ofExtension: extensionPath))
    }

    /// The bundle a copy of the extension belongs to: the app it's inside
    /// (`Side Tabs.app/Contents/PlugIns/Side Tabs Extension.appex`), or the extension itself when it's on its
    /// own, as Xcode leaves one beside the app it builds.
    static func bundle(ofExtension path: String) -> String {
        let appex = URL(fileURLWithPath: path).standardizedFileURL
        let plugIns = appex.deletingLastPathComponent()
        let contents = plugIns.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        if plugIns.lastPathComponent == "PlugIns", contents.lastPathComponent == "Contents", app.pathExtension == "app" {
            return app.path
        }
        return appex.path
    }

    /// Whether `path` is `bundle` or inside it. Case doesn't count, as on the Mac's own disk, and neither do
    /// `.`, `..` or a slash at the end.
    static func isInside(_ path: String, bundle: String) -> Bool {
        let path = normalized(path)
        let bundle = normalized(bundle)
        return path == bundle || path.hasPrefix(bundle + "/")
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }

    /// The extensions' paths in `pluginkit -m -v`'s listing. Each line is an extension's id and version, its
    /// UUID, when it was registered and its path, apart by tabs, after a mark for whether it's turned on.
    static func paths(inPluginkitListing listing: String) -> [String] {
        listing.split(separator: "\n").compactMap { line in
            guard let last = line.split(separator: "\t").last?.trimmingCharacters(in: .whitespaces),
                  last.hasPrefix("/"), last.hasSuffix(".appex") else { return nil }
            return last
        }
    }

    /// A path for the log: the home folder as `~`, so the log doesn't carry the user's name.
    static func describe(_ path: String?) -> String {
        guard let path else { return "a copy that doesn't say where it is" }
        let home = NSHomeDirectory()
        if path == home || path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
