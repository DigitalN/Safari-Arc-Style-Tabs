import AppKit
import os.log

/// Puts this app's extension in Safari's hands when Safari runs another copy's (#67, ExtensionCopyCheck), the way
/// it was fixed by hand on 2026-11-12: the other copies are unregistered from LaunchServices (`lsregister -u`) and
/// pluginkit (`pluginkit -r`), then this app is registered again (`lsregister -f -R`) and its extension added
/// (`pluginkit -a`). Safari then started this app's extension within a second, by itself.
///
/// It never deletes anything: a copy outside this app's bundle is the user's. The sidebar says where it is if
/// Safari keeps running it. Side Tabs isn't sandboxed, so it can run both tools.
nonisolated enum ExtensionRegistration {
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    private static let pluginkit = "/usr/bin/pluginkit"
    private static let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "bridge")

    /// Unregisters every other copy: `reported`, the one Safari runs if that's known, every copy of the extension
    /// pluginkit lists, and every copy of the app LaunchServices knows. Then registers this app and its extension.
    /// `done` runs on the main thread with the other copies (apps, or extensions on their own) it found.
    @MainActor
    static func repair(reported: String?, done: @escaping @MainActor ([String]) -> Void) {
        let own = Bundle.main.bundlePath
        let ownExtension = Bundle.main.builtInPlugInsPath.map { $0 + "/Side Tabs Extension.appex" }
            ?? own + "/Contents/PlugIns/Side Tabs Extension.appex"
        let apps = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: SideTabsBridge.appBundleIdentifier).map(\.path)
        DispatchQueue.global(qos: .utility).async {
            // Each other copy, with the extensions pluginkit lists in it.
            var others: [(bundle: String, extensions: [String])] = []
            func add(_ bundle: String, extension appex: String? = nil) {
                guard !ExtensionCopyCheck.isInside(bundle, bundle: own) else { return }
                if let index = others.firstIndex(where: { $0.bundle == bundle }) {
                    if let appex, !others[index].extensions.contains(appex) {
                        others[index].extensions.append(appex)
                    }
                } else {
                    others.append((bundle, appex.map { [$0] } ?? []))
                }
            }
            if let reported {
                add(reported)
            }
            for appex in registeredExtensions() {
                add(ExtensionCopyCheck.bundle(ofExtension: appex), extension: appex)
            }
            for app in apps {
                add(app)
            }

            log.notice("other copies registered with macOS: \(others.count)")
            for other in others {
                // An app's own extension, if pluginkit doesn't list it, is where Xcode puts it.
                var extensions = other.extensions
                if other.bundle.hasSuffix(".app"), extensions.isEmpty {
                    extensions = [other.bundle + "/Contents/PlugIns/Side Tabs Extension.appex"]
                }
                let unregistered = run(lsregister, ["-u", other.bundle])
                let removed = extensions.map { run(pluginkit, ["-r", $0]) }
                log.notice("unregistered the copy in \(ExtensionCopyCheck.describe(other.bundle), privacy: .public) (lsregister -u: \(unregistered), pluginkit -r: \(removed.map(String.init).joined(separator: ", "), privacy: .public)); it stays on disk")
            }
            let registered = run(lsregister, ["-f", "-R", own])
            let added = run(pluginkit, ["-a", ownExtension])
            log.notice("registered this app, \(ExtensionCopyCheck.describe(own), privacy: .public), and its extension (lsregister -f -R: \(registered), pluginkit -a: \(added))")
            let found = others.map(\.bundle)
            DispatchQueue.main.async {
                done(found)
            }
        }
    }

    /// The copies of the extension pluginkit lists, wherever they are, this app's among them.
    private static func registeredExtensions() -> [String] {
        let output = read(pluginkit, ["-m", "-A", "-D", "-v", "-i", SideTabsBridge.extensionBundleIdentifier])
        return ExtensionCopyCheck.paths(inPluginkitListing: output)
    }

    /// Runs a tool and says how it ended: its exit status, or -1 if it couldn't be started.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func read(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
