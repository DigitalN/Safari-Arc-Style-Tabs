/// Watches for a click on Safari's Dock icon (#42), for "Minimize other profiles' windows": while the
/// current profile has no open window, such a click should open a window in it, not bring back another
/// profile's (DockIconRule). SafariProfiles arms it while the rule applies and disarms it when the rule
/// stops applying; it listens only while armed, and calls `onClick` on the main thread.
///
/// Nil until wired: without it, the Dock icon brings back whatever macOS picks, as it does with the
/// setting off.
protocol SafariDockIconWatching: AnyObject {
    var onClick: (() -> Void)? { get set }
    func arm()
    func disarm()
}
