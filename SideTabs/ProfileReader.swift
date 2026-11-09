import AppKit
@preconcurrency import ApplicationServices
import os

/// The window server's id for an Accessibility window (see SafariWindowReader, which has its own
/// declaration of the same private call).
@_silgen_name("_AXUIElementGetWindow")
nonisolated private func profileReaderWindowNumber(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// An element of Safari's Accessibility tree, read for ProfileTree's searches. Its attributes are
/// read in one round trip the first time one is asked for, and its children only when asked for, so
/// a search that stops early reads little: finding File → New Window takes about ten round trips.
/// Only used on ProfileReader's queue.
nonisolated final class AXProfileNode: ProfileTreeNode, @unchecked Sendable {
    let element: AXUIElement
    private let query: AXQuery
    private var values: [CFTypeRef?]?

    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, "AXIdentifier",
        kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute,
    ]

    init(_ element: AXUIElement, query: AXQuery) {
        self.element = element
        self.query = query
    }

    private func value(_ index: Int) -> CFTypeRef? {
        if values == nil {
            values = query.copyMultiple(element, Self.attributes) ?? []
        }
        guard let values, values.indices.contains(index) else { return nil }
        return values[index]
    }

    var role: String? { value(0) as? String }
    var subrole: String? { value(1) as? String }
    var identifier: String? { value(2) as? String }
    var commandCharacter: String? { value(3) as? String }
    var commandModifiers: Int? { value(4) as? Int }

    func children() -> [AXProfileNode] {
        query.elements(element, kAXChildrenAttribute).map { AXProfileNode($0, query: query) }
    }
}

/// One of Safari's windows, as a switch needs to know it.
nonisolated struct SafariWindowInfo: @unchecked Sendable {
    let element: AXUIElement
    let number: Int
    let isMinimized: Bool
    let isFullScreen: Bool
    /// The page's title after the profile's name. Never logged.
    let title: String?
    let toolbar: ToolbarProfile
}

/// Reads what Safari says about its profiles through Accessibility, off the main thread: the
/// File → New Window menu, each window's toolbar profile button, and the list of windows.
///
/// Every call waits for Safari's main thread, so everything here runs on `queue`, never the main
/// thread, and what doesn't change is kept: a window's profile never does, so its toolbar is read
/// once per window.
nonisolated final class ProfileReader: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.digitaln.sidetabs.accessibility-profiles", qos: .userInitiated)
    let query = AXQuery(timeout: 0.5)
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "profiles")

    // Only used on `queue`.
    /// File → New Window's items from the last read, for pressing.
    private(set) var newWindowItems: [(node: AXProfileNode, profile: MenuProfile)] = []
    /// Safari → Manage Profiles…, once found.
    private var manageProfilesItem: AXUIElement?
    /// Each window's profile, by window number. A window's profile never changes.
    private var toolbars: [Int: ToolbarProfile] = [:]
    /// When each window was first seen, so a toolbar read right after it opened, before Safari has
    /// added the profile button (it takes up to 50 ms), isn't kept as "no profile".
    private var firstSeen: [Int: Date] = [:]
    private static let settleTime: TimeInterval = 0.5

    struct MenuReading: Sendable {
        let profiles: [MenuProfile]
        let milliseconds: Int
    }

    // MARK: - Menus

    /// File → New Window, in Safari's order, or nil if Safari didn't answer or has no File menu yet.
    /// Call on `queue`.
    func readMenu(application: AXUIElement) -> MenuReading? {
        let started = Date()
        query.clearTimedOut()
        guard let menuBar = query.element(application, kAXMenuBarAttribute) else { return nil }
        let result = ProfileTree.newWindowMenu(in: AXProfileNode(menuBar, query: query))
        guard let result, !query.timedOut else { return nil }
        let profiles: [MenuProfile]
        switch result {
        case .profiles(let items):
            newWindowItems = items
            profiles = items.map(\.profile)
        case .singleProfile:
            newWindowItems = []
            profiles = [MenuProfile(name: "", isDefault: true)]
        }
        return MenuReading(profiles: profiles, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// Safari → Manage Profiles…, found once per Safari launch. Call on `queue`.
    func manageProfiles(application: AXUIElement) -> AXUIElement? {
        if let manageProfilesItem {
            return manageProfilesItem
        }
        guard let menuBar = query.element(application, kAXMenuBarAttribute) else { return nil }
        manageProfilesItem = ProfileTree.manageProfilesItem(in: AXProfileNode(menuBar, query: query))?.element
        return manageProfilesItem
    }

    // MARK: - Windows

    /// The window server's number for a window.
    func number(of window: AXUIElement) -> Int? {
        var id: CGWindowID = 0
        guard profileReaderWindowNumber(window, &id) == .success, id != 0 else { return nil }
        return Int(id)
    }

    /// A window's profile, from its toolbar, read once per window. Call on `queue`.
    func toolbarProfile(of window: AXUIElement) -> (number: Int?, profile: ToolbarProfile) {
        guard let number = number(of: window) else {
            return (nil, readToolbar(window))
        }
        if let known = toolbars[number] {
            return (number, known)
        }
        let seen = firstSeen[number] ?? Date()
        firstSeen[number] = seen
        let profile = readToolbar(window)
        switch profile {
        case .profile:
            toolbars[number] = profile
        case .noProfileButton where Date().timeIntervalSince(seen) > Self.settleTime:
            toolbars[number] = profile
        case .noProfileButton, .unknown:
            break
        }
        return (number, profile)
    }

    private func readToolbar(_ window: AXUIElement) -> ToolbarProfile {
        query.clearTimedOut()
        let profile = ProfileTree.toolbarProfile(of: AXProfileNode(window, query: query))
        return query.timedOut ? .unknown : profile
    }

    /// Safari's browser windows, front to back, with each one's profile. Settings and other
    /// windows that aren't browser windows are left out. Call on `queue`.
    func windows(application: AXUIElement) -> [SafariWindowInfo] {
        query.clearTimedOut()
        var result: [SafariWindowInfo] = []
        for element in query.elements(application, kAXWindowsAttribute) {
            let values = query.copyMultiple(element, ["AXIdentifier", kAXMinimizedAttribute, "AXFullScreen", kAXTitleAttribute]) ?? []
            func value(_ index: Int) -> CFTypeRef? { values.indices.contains(index) ? values[index] : nil }
            guard ProfileIdentifiers.isBrowserWindow(value(0) as? String), let number = number(of: element) else { continue }
            let toolbar = toolbarProfile(of: element).profile
            result.append(SafariWindowInfo(
                element: element,
                number: number,
                isMinimized: value(1) as? Bool ?? false,
                isFullScreen: value(2) as? Bool ?? false,
                title: value(3) as? String,
                toolbar: toolbar
            ))
        }
        return result
    }

    /// The numbers of Safari's windows, to spot a new one. Call on `queue`.
    func windowNumbers(application: AXUIElement) -> Set<Int> {
        Set(query.elements(application, kAXWindowsAttribute).compactMap(number(of:)))
    }

    /// Whether Safari's focused window is a browser window (false for Settings and the like), or nil
    /// if it has none or didn't answer. Call on `queue`.
    func focusedWindowIsBrowser(application: AXUIElement) -> Bool? {
        query.clearTimedOut()
        guard let focused = query.element(application, kAXFocusedWindowAttribute) else { return nil }
        let identifier = query.string(focused, "AXIdentifier")
        if query.timedOut { return nil }
        return ProfileIdentifiers.isBrowserWindow(identifier)
    }

    /// Forgets each window's profile, which changes when a profile is renamed or given another symbol
    /// in Settings. Call on `queue`.
    func forgetToolbars() {
        toolbars = [:]
    }

    /// Forgets everything that belongs to one Safari launch. Call on `queue`.
    func forget() {
        newWindowItems = []
        manageProfilesItem = nil
        toolbars = [:]
        firstSeen = [:]
    }
}
