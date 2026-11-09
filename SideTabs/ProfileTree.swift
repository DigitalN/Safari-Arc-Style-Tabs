import Foundation

// Where Safari keeps what Side Tabs reads and presses for profiles, in its Accessibility tree: the
// File → New Window submenu, Safari → Manage Profiles…, each window's toolbar profile button, and
// the Profiles pane in Settings. Kept apart from the Accessibility calls (ProfileReader) so it can
// be checked against recorded trees (Tests/TabBarFinderChecks/trees) without Safari.
//
// Everything is found by identifier, role and position, never by a title: titles are translated.

/// One element of Safari's Accessibility tree, as far as these searches need to know it. The real
/// ones read their attributes from Safari (ProfileReader.swift); the checks use recorded ones.
nonisolated protocol ProfileTreeNode {
    var role: String? { get }
    var subrole: String? { get }
    /// `AXIdentifier`: not shown to anyone, and not translated.
    var identifier: String? { get }
    /// `AXMenuItemCmdChar` and `AXMenuItemCmdModifiers`, for menu items.
    var commandCharacter: String? { get }
    var commandModifiers: Int? { get }
    /// Reading the children costs a round trip to Safari, so the searches read only where they must.
    func children() -> [Self]
}

nonisolated enum ProfileTree {
    // MARK: - Menus

    /// Safari's menu bar: Apple, Safari, File, … The File menu is tried at its usual place first.
    static let applicationMenuIndex = 1
    static let fileMenuIndex = 2

    /// The menu (the `AXMenu` under a menu bar item) whose identifier is `identifier`. Looks at the
    /// usual position first, then at every menu bar item, reading only each item's own menu.
    static func menu<Node: ProfileTreeNode>(_ identifier: String, usually index: Int, in menuBar: Node) -> Node? {
        let items = menuBar.children()
        func menu(under item: Node) -> Node? {
            item.children().first { $0.role == "AXMenu" && $0.identifier == identifier }
        }
        if items.indices.contains(index), let found = menu(under: items[index]) {
            return found
        }
        for (position, item) in items.enumerated() where position != index {
            if let found = menu(under: item) {
                return found
            }
        }
        return nil
    }

    /// What File → New Window says, or nil if the File menu can't be found.
    enum NewWindowMenu<Node: ProfileTreeNode> {
        /// One item per profile, in order.
        case profiles([(node: Node, profile: MenuProfile)])
        /// File → New Window is a plain item: Safari has only the default profile.
        case singleProfile
    }

    static func newWindowMenu<Node: ProfileTreeNode>(in menuBar: Node) -> NewWindowMenu<Node>? {
        guard let fileMenu = menu(ProfileIdentifiers.fileMenu, usually: fileMenuIndex, in: menuBar) else { return nil }
        guard let submenuItem = fileMenu.children().first(where: { $0.identifier == ProfileIdentifiers.newWindowSubmenuItem }),
              let submenu = submenuItem.children().first(where: { $0.role == "AXMenu" }) else {
            return .singleProfile
        }
        var entries: [(node: Node, profile: MenuProfile)] = []
        for item in submenu.children() {
            let parsed = ProfileIdentifiers.menuProfiles([(item.identifier, item.commandCharacter, item.commandModifiers)])
            if let profile = parsed.first {
                entries.append((item, profile))
            }
        }
        return entries.isEmpty ? .singleProfile : .profiles(entries)
    }

    /// Safari → Manage Profiles…
    static func manageProfilesItem<Node: ProfileTreeNode>(in menuBar: Node) -> Node? {
        menu(ProfileIdentifiers.applicationMenu, usually: applicationMenuIndex, in: menuBar)?
            .children().first { $0.identifier == ProfileIdentifiers.manageProfilesItem }
    }

    /// The File → New Window item for `profile`, the one at `position` in Safari's order. If the
    /// menu has changed since (the item there is another profile's), the one item with the same
    /// name and flag, if there is exactly one. Nil means the menu should be read again.
    static func newWindowItem<Node>(for profile: SafariProfile, at position: Int, among items: [(node: Node, profile: MenuProfile)]) -> Node? {
        func fits(_ entry: MenuProfile) -> Bool {
            entry.isDefault == profile.isDefault && ProfileIdentifiers.sameName(entry.name, profile.name)
        }
        if items.indices.contains(position), fits(items[position].profile) {
            return items[position].node
        }
        let matches = items.filter { fits($0.profile) }
        return matches.count == 1 ? matches[0].node : nil
    }

    // MARK: - A window's toolbar

    /// The window's profile, from its toolbar's profile button. Reads only the window's direct
    /// children, the toolbar's, and those of plain groups in it; never the page, the tab bar (an
    /// `AXOpaqueProviderGroup`, which has a button per tab) or the area beside it.
    static func toolbarProfile<Node: ProfileTreeNode>(of window: Node) -> ToolbarProfile {
        var toolbar: Node?
        for child in window.children() {
            if child.role == "AXToolbar" {
                toolbar = child
                break
            }
            // In full screen the toolbar is inside a group.
            if child.role == "AXGroup", let inner = child.children().first(where: { $0.role == "AXToolbar" }) {
                toolbar = inner
                break
            }
        }
        guard let toolbar else { return .unknown }
        var groups: [Node] = []
        for item in toolbar.children() {
            if ProfileIdentifiers.isProfileButton(item.identifier) {
                return profile(fromButton: item.identifier)
            }
            if item.role == "AXGroup" {
                groups.append(item)
            }
        }
        for group in groups {
            for item in group.children() where ProfileIdentifiers.isProfileButton(item.identifier) {
                return profile(fromButton: item.identifier)
            }
        }
        return .noProfileButton
    }

    private static func profile(fromButton identifier: String?) -> ToolbarProfile {
        guard let parsed = ProfileIdentifiers.toolbarButton(identifier) else {
            // The button is there but names no profile.
            return .profile(name: "", symbol: nil)
        }
        return .profile(name: parsed.name, symbol: parsed.symbol)
    }

    // MARK: - Settings → Profiles

    /// The Profiles pane (`SafariProfilesPreferencesView`), if `window` is Settings showing it.
    static func profilesPane<Node: ProfileTreeNode>(in window: Node) -> Node? {
        guard !ProfileIdentifiers.isBrowserWindow(window.identifier) else { return nil }
        for child in window.children() where child.role == "AXGroup" {
            if child.identifier == ProfileIdentifiers.profilesPane {
                return child
            }
            if let pane = child.children().first(where: { $0.identifier == ProfileIdentifiers.profilesPane }) {
                return pane
            }
        }
        return nil
    }

    /// The pane's list of profiles: the `AXTable` in its scroll area.
    static func profilesTable<Node: ProfileTreeNode>(in pane: Node) -> Node? {
        for child in pane.children() where child.role == "AXScrollArea" {
            if let table = child.children().first(where: { $0.role == "AXTable" }) {
                return table
            }
        }
        return nil
    }

    /// The pane's tabs (General, Extensions), in order. The default profile has no Extensions tab.
    static func profileTabs<Node: ProfileTreeNode>(in pane: Node) -> [Node] {
        guard let tabGroup = pane.children().first(where: { $0.role == "AXTabGroup" }) else { return [] }
        return tabGroup.children().filter { $0.role == "AXRadioButton" }
    }

    /// The Extensions tab is the second one.
    static let extensionsTabIndex = 1
}
