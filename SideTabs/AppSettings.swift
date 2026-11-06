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

    var autoHideSidebar: Bool {
        didSet { defaults.set(autoHideSidebar, forKey: "autoHideSidebar") }
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

    var tabCleanupInterval: TabCleanupInterval {
        didSet { defaults.set(tabCleanupInterval.rawValue, forKey: "tabCleanupInterval") }
    }

    /// Check GitHub for new versions and install them in the background.
    var updatesAutomatically: Bool {
        didSet { defaults.set(updatesAutomatically, forKey: "updatesAutomatically") }
    }

    /// The user finished setup after Accessibility, the extension and readable tabs worked.
    var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }

    /// Safari's extension starts Side Tabs when the browser opens. Remove the old
    /// independent login item once so Side Tabs doesn't stay alive after Safari quits.
    func followSafariInsteadOfLogin() {
        guard !defaults.bool(forKey: "safariLifecycleMigrationApplied") else { return }
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            defaults.set(true, forKey: "safariLifecycleMigrationApplied")
        } catch {
            NSLog("Side Tabs: could not remove old login item: \(error)")
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "sidebarVisible": true,
            "autoHideSidebar": false,
            "sidebarWidth": 260.0,
            "closeButtonMode": CloseButtonMode.hover.rawValue,
            "showBookmarks": true,
            "tabCleanupInterval": TabCleanupInterval.off.rawValue,
            "hasCompletedSetup": false,
            "updatesAutomatically": true,
        ])
        // Explicit launch option for enabling the same persisted Settings preference.
        if CommandLine.arguments.contains("--auto-hide-sidebar") {
            defaults.set(true, forKey: "autoHideSidebar")
        }
        sidebarVisible = defaults.bool(forKey: "sidebarVisible")
        autoHideSidebar = defaults.bool(forKey: "autoHideSidebar")
        width = defaults.double(forKey: "sidebarWidth").clamped(to: Self.widthRange)
        closeButtonMode = CloseButtonMode(rawValue: defaults.string(forKey: "closeButtonMode") ?? "") ?? .hover
        showBookmarks = defaults.bool(forKey: "showBookmarks")
        tabCleanupInterval = TabCleanupInterval(rawValue: defaults.string(forKey: "tabCleanupInterval") ?? "") ?? .off
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
        updatesAutomatically = defaults.bool(forKey: "updatesAutomatically")
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
