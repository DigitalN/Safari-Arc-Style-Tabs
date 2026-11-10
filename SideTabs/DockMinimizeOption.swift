import CoreFoundation
import Foundation

/// The Mac's "Minimize windows into application icon" option, in Desktop & Dock. With "Minimize other
/// profiles' windows" on (#42), every minimized window gets a tile of its own in the Dock unless this
/// option is on, so Settings recommends it. Side Tabs only reads the option: it never changes the
/// Dock's settings.
enum DockMinimizeOption {
    /// Desktop & Dock in System Settings, where the option is.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")

    /// Whether Settings recommends the option: while "Minimize other profiles' windows" is on and the
    /// option is off.
    static func recommends(minimizesOtherProfiles: Bool, minimizesIntoApplicationIcon: Bool) -> Bool {
        minimizesOtherProfiles && !minimizesIntoApplicationIcon
    }

    /// Reads the option from the Dock's preferences. It's off when it was never set, as on a new Mac.
    /// System Settings changes it from another process, so this synchronizes first rather than trusting
    /// what this process read last time. Side Tabs isn't sandboxed, so it can read the Dock's domain.
    static func readMinimizesIntoApplicationIcon() -> Bool {
        let dock = "com.apple.dock" as CFString
        _ = CFPreferencesAppSynchronize(dock)
        return CFPreferencesGetAppBooleanValue("minimize-to-application" as CFString, dock, nil)
    }
}
