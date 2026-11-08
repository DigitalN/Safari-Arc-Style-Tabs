import ApplicationServices

/// The notifications the sidebar asks Safari for on the window it's docked to, and what they mean.
/// Kept apart from the Accessibility observer (SafariWindowReader registers them, SafariTracker
/// receives them) so it can be checked without Safari.
nonisolated enum DockedWindowNotifications {
    /// Reported by the docked window itself, on top of the application-wide ones.
    static let names: [String] = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        // Safari titles a window after its current page, so this changes with every tab switch and
        // page title. The sidebar's copy of the title picks the window to list when a profile has
        // several, so it has to follow (see TabStore.dockedWindowTitle).
        kAXTitleChangedNotification,
    ]

    /// Whether the notification says only that the title changed: nothing about where the window is,
    /// how big, or whether it is still there, so the dock's layout has nothing to redo.
    static func isTitleChange(_ name: String) -> Bool {
        name == kAXTitleChangedNotification
    }
}
