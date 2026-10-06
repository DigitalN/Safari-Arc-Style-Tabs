import Foundation
import Observation
import ServiceManagement

@Observable
final class AppSettings {
    enum CloseButtonMode: String, CaseIterable, Identifiable {
        case hover, always
        var id: String { rawValue }
    }

    static let widthRange: ClosedRange<Double> = 180...420

    var sidebarVisible: Bool {
        didSet { defaults.set(sidebarVisible, forKey: "sidebarVisible") }
    }

    var width: Double {
        didSet { defaults.set(width, forKey: "sidebarWidth") }
    }

    var closeButtonMode: CloseButtonMode {
        didSet { defaults.set(closeButtonMode.rawValue, forKey: "closeButtonMode") }
    }

    var showBookmarks: Bool {
        didSet { defaults.set(showBookmarks, forKey: "showBookmarks") }
    }

    /// Accessibility and the Safari extension have both been turned on.
    var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Side Tabs: could not change login item: \(error)")
            }
            launchAtLoginRevision += 1
        }
    }

    /// Bumped so views re-read `launchAtLogin`, which lives in ServiceManagement.
    private var launchAtLoginRevision = 0

    /// Open at login starts out on. It's only switched on once, so turning it off sticks.
    /// Call this from Applications: the login item points at wherever the app is running.
    func turnOnLaunchAtLoginByDefault() {
        guard !defaults.bool(forKey: "launchAtLoginDefaultApplied") else { return }
        defaults.set(true, forKey: "launchAtLoginDefaultApplied")
        if !launchAtLogin {
            launchAtLogin = true
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "sidebarVisible": true,
            "sidebarWidth": 260.0,
            "closeButtonMode": CloseButtonMode.hover.rawValue,
            "showBookmarks": true,
            "hasCompletedSetup": false,
        ])
        sidebarVisible = defaults.bool(forKey: "sidebarVisible")
        width = defaults.double(forKey: "sidebarWidth").clamped(to: Self.widthRange)
        closeButtonMode = CloseButtonMode(rawValue: defaults.string(forKey: "closeButtonMode") ?? "") ?? .hover
        showBookmarks = defaults.bool(forKey: "showBookmarks")
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
    }

    func launchAtLoginStatus() -> Bool {
        _ = launchAtLoginRevision
        return launchAtLogin
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
