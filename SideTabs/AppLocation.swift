import AppKit

/// Side Tabs has to run from an Applications folder. Opened straight from the downloaded
/// disk image or the Downloads folder, macOS runs a temporary hidden copy ("app
/// translocation"), so Safari can't find the extension and the Accessibility permission
/// doesn't stick. On launch from anywhere else, offer to move it.
enum AppLocation {
    static let releasesURL = URL(string: "https://github.com/DigitalN/Safari-Arc-Style-Tabs/releases")!

    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let folders = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        return folders.contains { path.hasPrefix($0) }
    }

    /// Asks to move the app. Returns true if the app is relaunching from Applications.
    static func offerToMove() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Side Tabs to your Applications folder?"
        alert.informativeText = "Side Tabs needs to be in Applications so Safari can find its extension and macOS remembers its permissions."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let source = Bundle.main.bundleURL
        let name = source.lastPathComponent
        let candidates = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
        for folder in candidates {
            let destination = folder.appending(path: name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                // The user already chose to open this download; don't make them approve
                // the copy again.
                let xattr = Process()
                xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
                try? xattr.run()
                xattr.waitUntilExit()
                relaunch(from: destination)
                return true
            } catch {
                continue
            }
        }

        let failure = NSAlert()
        failure.messageText = "Side Tabs couldn't move itself"
        failure.informativeText = "Quit Side Tabs, drag it into your Applications folder in Finder, then open it from there."
        failure.runModal()
        return false
    }

    private static func relaunch(from url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "sh", url.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
