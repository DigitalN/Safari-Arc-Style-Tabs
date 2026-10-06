import AppKit
import Observation
import Security
import os.log

/// Keeps Side Tabs up to date from its GitHub releases, with nothing to click or drag.
///
/// Each time Safari starts, it asks GitHub for the latest release. If that's newer, it
/// downloads the release's disk image in the background, copies the app out of it, and
/// checks that it's signed by the same developer team as this copy. Then, at a moment when
/// nobody is using the Mac, it swaps the new app in and relaunches into it.
///
/// A release counts when it's the repository's latest (not a draft or pre-release), its tag
/// is the version (`v1.2`), and the `.dmg` from `scripts/package.sh` is attached.
///
/// An app downloaded this way isn't marked as coming from the internet, so macOS doesn't ask
/// to approve it again. The signature check is what makes that safe: only an app signed with
/// a certificate from the same team can replace this one.
@Observable
final class Updater {
    enum Status: Equatable {
        case idle
        case checking
        case downloading(version: String)
        /// Downloaded and verified, waiting for a quiet moment to relaunch.
        case ready(version: String)
    }

    private(set) var status: Status = .idle

    /// Why this copy can't update itself, or nil if it can. "Check for Updates…" then opens
    /// the releases page instead.
    let unavailableReason: String?

    /// Whether someone is in the middle of something in Side Tabs (renaming a tab, going
    /// through setup), so it shouldn't relaunch on its own right now.
    @ObservationIgnored var isBusy: () -> Bool = { false }
    /// Called just before quitting to relaunch into the update.
    @ObservationIgnored var willRelaunch: (() -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let teamIdentifier: String?
    @ObservationIgnored private var safariLaunchObserver: NSObjectProtocol?
    /// Runs while a downloaded update waits for a quiet moment.
    @ObservationIgnored private var installTimer: Timer?
    @ObservationIgnored private var staged: StagedUpdate?
    /// A version that failed to download, verify or install. Not retried automatically, so a
    /// broken release doesn't get downloaded again every time Safari starts.
    @ObservationIgnored private var failedVersion: String?

    /// How long the Mac has to go without keyboard or mouse input before relaunching.
    private static let quietInterval: TimeInterval = 10

    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "updates")

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// GitHub's API for the newest published release. For testing, the `UpdateFeedURL`
    /// default can point somewhere else (a `file://` URL works); the signature check still
    /// applies to whatever it finds there.
    private var feedURL: URL {
        if let override = UserDefaults.standard.string(forKey: "UpdateFeedURL"), let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(AppLocation.repository)/releases/latest")!
    }

    init(settings: AppSettings) {
        self.settings = settings
        teamIdentifier = Self.ownTeamIdentifier()
        let installed = Bundle.main.bundleURL
        if teamIdentifier == nil {
            unavailableReason = "this copy isn't signed by a developer team, so updates can't be verified"
        } else if !AppLocation.isInApplicationsFolder {
            unavailableReason = "Side Tabs isn't in the Applications folder"
        } else if !FileManager.default.isWritableFile(atPath: installed.path)
                    || !FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path) {
            unavailableReason = "Side Tabs can't replace itself in \(installed.deletingLastPathComponent().path)"
        } else {
            unavailableReason = nil
        }
    }

    func start() {
        if let unavailableReason {
            log.notice("automatic updates off: \(unavailableReason, privacy: .public)")
            return
        }
        safariLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == SafariTracker.safariBundleID else { return }
            MainActor.assumeIsolated { self?.checkAutomatically() }
        }
        // Safari may have started first, e.g. when both open at login.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: SafariTracker.safariBundleID).isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkAutomatically() }
        }
    }

    private func checkAutomatically() {
        guard settings.updatesAutomatically, status == .idle else { return }
        Task { await check(userInitiated: false) }
    }

    /// "Check for Updates…" in the menu: check now and install right away, or say why not.
    func checkNow() {
        guard unavailableReason == nil else {
            NSWorkspace.shared.open(AppLocation.releasesURL)
            return
        }
        switch status {
        case .ready:
            install()
        case .idle:
            Task { await check(userInitiated: true) }
        case .checking, .downloading:
            break
        }
    }

    // MARK: - Checking and downloading

    private func check(userInitiated: Bool) async {
        status = .checking
        var version: String?
        do {
            guard let release = try await latestRelease(),
                  Self.isVersion(release.version, newerThan: Self.currentVersion) else {
                status = .idle
                log.notice("up to date at \(Self.currentVersion, privacy: .public)")
                if userInitiated {
                    showAlert("Side Tabs is up to date", "You have the latest version, \(Self.currentVersion).")
                }
                return
            }
            version = release.version
            if release.version == failedVersion && !userInitiated {
                status = .idle
                return
            }
            log.notice("downloading \(release.version, privacy: .public)")
            status = .downloading(version: release.version)
            staged = try await download(release)
            status = .ready(version: release.version)
            log.notice("\(release.version, privacy: .public) is ready to install")
            if userInitiated {
                install()
            } else {
                installIfQuiet()
            }
        } catch {
            status = .idle
            if let version {
                failedVersion = version
            }
            log.error("update check failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated {
                showFailure(error.localizedDescription)
            }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }

        var version: String {
            tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }

        var diskImage: URL? {
            assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadUrl
        }
    }

    /// The latest release, or nil if the repository has none yet.
    private func latestRelease() async throws -> Release? {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                return nil
            }
            guard http.statusCode == 200 else {
                throw UpdateError.server(http.statusCode)
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    private struct StagedUpdate {
        let version: String
        /// The verified app, on the same volume as the installed one so the swap is a rename.
        let app: URL
        /// The temporary folder holding it.
        let folder: URL
    }

    private func download(_ release: Release) async throws -> StagedUpdate {
        guard let source = release.diskImage, let teamIdentifier else {
            throw UpdateError.noDiskImage
        }
        let installed = Bundle.main.bundleURL
        let folder = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true
        )
        do {
            let (downloaded, response) = try await URLSession.shared.download(from: source)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.server(http.statusCode)
            }
            let image = folder.appending(path: "update.dmg")
            try FileManager.default.moveItem(at: downloaded, to: image)
            let app = folder.appending(path: installed.lastPathComponent)
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? SideTabsBridge.appBundleIdentifier
            let version = try await Task.detached {
                try Self.copyApp(from: image, to: app, bundleIdentifier: bundleIdentifier)
                try? FileManager.default.removeItem(at: image)
                return try Self.verify(app, teamIdentifier: teamIdentifier, bundleIdentifier: bundleIdentifier)
            }.value
            // The tag can be newer than the app inside if a release was put together wrong.
            guard Self.isVersion(version, newerThan: Self.currentVersion) else {
                throw UpdateError.notNewer(version)
            }
            return StagedUpdate(version: version, app: app, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Opens the disk image without showing it in Finder, copies Side Tabs out of it, and
    /// ejects it. It's mounted in /Volumes like any other disk image: mounted anywhere else,
    /// macOS's file access protection blocks reading it.
    nonisolated private static func copyApp(from image: URL, to destination: URL, bundleIdentifier: String) throws {
        let output = try run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-plist"])
        let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.appNotFound
        }
        defer { try? run("/usr/bin/hdiutil", ["detach", mountPath, "-force"]) }

        let apps = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: mountPath, isDirectory: true), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "app" }
        guard let app = apps.first(where: { infoValue("CFBundleIdentifier", in: $0) == bundleIdentifier }) else {
            throw UpdateError.appNotFound
        }
        try run("/usr/bin/ditto", [app.path, destination.path])
    }

    /// Checks that the whole app, extension included, is intact and signed by this team for
    /// this bundle identifier, and returns its version.
    nonisolated private static func verify(_ app: URL, teamIdentifier: String, bundleIdentifier: String) throws -> String {
        let requirementText = "identifier \"\(bundleIdentifier)\" and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateError.untrusted(errSecCSUnsigned)
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let result = SecStaticCodeCheckValidity(code, flags, requirement)
        guard result == errSecSuccess else {
            throw UpdateError.untrusted(result)
        }
        guard let version = infoValue("CFBundleShortVersionString", in: app) else {
            throw UpdateError.appNotFound
        }
        return version
    }

    // MARK: - Installing

    private func installIfQuiet() {
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard settings.updatesAutomatically, idle >= Self.quietInterval, NSEvent.pressedMouseButtons == 0, !isBusy() else {
            // Try again in a bit. A plain scheduled timer also waits while a menu is open, so
            // it never relaunches out from under one.
            if installTimer == nil {
                installTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.installIfQuiet() }
                }
            }
            return
        }
        install()
    }

    private func install() {
        installTimer?.invalidate()
        installTimer = nil
        guard let update = staged else { return }
        staged = nil
        do {
            // Swaps the two folders in one step, so there's never a moment without an app.
            // Only the new copy's metadata is kept, so nothing from the original download
            // (like the quarantine flag macOS checked on first launch) carries over.
            _ = try FileManager.default.replaceItemAt(
                Bundle.main.bundleURL, withItemAt: update.app, backupItemName: nil, options: .usingNewMetadataOnly
            )
        } catch {
            try? FileManager.default.removeItem(at: update.folder)
            status = .idle
            failedVersion = update.version
            log.error("couldn't install \(update.version, privacy: .public): \(error.localizedDescription, privacy: .public)")
            showFailure("Side Tabs couldn't replace itself in the Applications folder.")
            return
        }
        try? FileManager.default.removeItem(at: update.folder)
        log.notice("installed \(update.version, privacy: .public); relaunching")
        willRelaunch?()
        AppLocation.relaunch(inBackground: true)
    }

    // MARK: - Messages

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func showFailure(_ reason: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Side Tabs couldn't update itself"
        alert.informativeText = "\(reason) You can download the latest version from GitHub instead."
        alert.addButton(withTitle: "Open Releases Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(AppLocation.releasesURL)
        }
    }

    // MARK: - Helpers

    /// Compares dotted versions number by number, so 1.10 is newer than 1.9.
    static func isVersion(_ version: String, newerThan other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Reads Info.plist directly: `Bundle` caches by path, which would go stale here.
    nonisolated private static func infoValue(_ key: String, in app: URL) -> String? {
        NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?[key] as? String
    }

    /// Runs a command line tool to completion and returns what it printed.
    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.toolFailed(URL(fileURLWithPath: tool).lastPathComponent, process.terminationStatus)
        }
        return data
    }
}

nonisolated enum UpdateError: LocalizedError {
    case server(Int)
    case noDiskImage
    case appNotFound
    case untrusted(OSStatus)
    case notNewer(String)
    case toolFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .server(let code):
            "GitHub answered with an error (\(code))."
        case .noDiskImage:
            "The latest release has no disk image attached."
        case .appNotFound:
            "The latest release's disk image doesn't contain Side Tabs."
        case .untrusted(let status):
            "The downloaded app was changed or isn't signed by the Side Tabs developer (\(status))."
        case .notNewer(let version):
            "The latest release contains version \(version), which isn't newer than this one."
        case .toolFailed(let tool, let status):
            "\(tool) failed (\(status))."
        }
    }
}
