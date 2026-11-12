// What Check for Updates… shows for each of the updater's states. The menu bar menu and Settings →
// General both show it (#70), so they read it from here and always agree. Kept apart from the updater
// and SwiftUI so a check can compile it on its own.

/// Where the updater is (`Updater.Status`).
nonisolated enum UpdateStatus: Equatable {
    case idle
    case checking
    case downloading(version: String)
    /// Downloaded and verified, waiting for a quiet moment to relaunch.
    case ready(version: String)
}

/// The control beside the version, in the menu and in Settings: a button that calls
/// `Updater.checkNow()` while there's something to click, and text that can't be clicked while the
/// updater is busy. A copy that can't update itself stays `.idle`, so its button reads Check for
/// Updates… and `checkNow()` opens the releases page.
nonisolated struct UpdateControl: Equatable {
    let title: String
    /// Whether clicking it calls `Updater.checkNow()`.
    let isButton: Bool

    init(_ status: UpdateStatus) {
        switch status {
        case .idle:
            title = "Check for Updates…"
            isButton = true
        case .checking:
            title = "Checking for Updates…"
            isButton = false
        case .downloading(let version):
            title = "Downloading Side Tabs \(version)…"
            isButton = false
        case .ready(let version):
            title = "Restart to Update to \(version)"
            isButton = true
        }
    }
}
