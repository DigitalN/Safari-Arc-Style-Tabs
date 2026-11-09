import Foundation

// Checks for the profile buttons (#33): reading Safari's profile identifiers, finding them in its
// Accessibility tree, keeping the list up to date, telling which profile a window is in, which
// extension copy is a profile's, when Side Tabs counts as off in a profile, which window a switch
// brings forward, and what profiles.json keeps across a restart. No Safari involved.
//
// The trees are in ../TabBarFinderChecks/trees, recorded by #28 on Safari 27 with three profiles: the
// default "Personal" (person.fill), a second "Personal" (person.lanyardcard.fill) and "Work"
// (graduationcap.fill). Real names were replaced with these before they were kept.
//
//   safari-menubar-personal-window-front.json         The Safari, File and View menus; ⌘N is on the
//   safari-menubar-second-personal-window-front.json  first item in one and on the third in the other.
//   window-personal-test-page.json, window-work-new-window-start-page.json, window-private.json,
//   window-personal-minimized-real.json               Windows: two profiles, private, minimized.
//   settings-profiles-*.json, settings-extensions-pane.json   Safari's Settings.
//   compact-window.json, compact-fullscreen.json      Safari 26 (#20), whose profile button named no
//                                                     profile; in full screen the toolbar is in a group.
//   constructed-file-menu-two-profiles.json           Made up from a screenshot of Safari 27.2 with two
//                                                     profiles (#40): no New Window submenu, the profiles'
//                                                     items at the top of the File menu, the default first
//                                                     with ⌥⇧⌘0, the front window's with ⌘N. The identifiers
//                                                     are assumed to be the submenu's; the live test checks.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

// MARK: - Recorded trees

/// Which elements a search read the children of, as `role#identifier`. Each read is a round trip
/// to Safari, so the searches should read only what they need.
nonisolated(unsafe) var reads: [String] = []

struct Node: Decodable, ProfileTreeNode {
    var role: String?
    var subrole: String?
    var identifier: String?
    var title: String?
    var commandCharacter: String?
    var commandModifiers: Int?
    var kids: [Node]

    enum CodingKeys: String, CodingKey {
        case role, subrole, identifier, title
        case commandCharacter = "cmdChar"
        case commandModifiers = "cmdModifiers"
        case kids = "children"
    }

    init(role: String? = nil, identifier: String? = nil, title: String? = nil, commandCharacter: String? = nil, commandModifiers: Int? = nil, _ kids: [Node] = []) {
        self.role = role
        self.identifier = identifier
        self.title = title
        self.commandCharacter = commandCharacter
        self.commandModifiers = commandModifiers
        self.kids = kids
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decodeIfPresent(String.self, forKey: .role)
        subrole = try values.decodeIfPresent(String.self, forKey: .subrole)
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        commandCharacter = try values.decodeIfPresent(String.self, forKey: .commandCharacter)
        commandModifiers = try values.decodeIfPresent(Int.self, forKey: .commandModifiers)
        kids = try values.decodeIfPresent([Node].self, forKey: .kids) ?? []
    }

    func children() -> [Node] {
        reads.append("\(role ?? "?")#\(identifier ?? "")")
        return kids
    }
}

let treesFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "TabBarFinderChecks/trees")

func tree(_ name: String) -> Node {
    do {
        return try JSONDecoder().decode(Node.self, from: Data(contentsOf: treesFolder.appending(path: "\(name).json")))
    } catch {
        print("FAIL: can't read tree \(name): \(error)")
        exit(1)
    }
}

// MARK: - Identifiers

do {
    let personal = ProfileIdentifiers.menuItem("NewPersonalWindow?isDefaultProfile=true")
    check(personal?.name == "Personal" && personal?.isDefault == true, "default profile's menu item")
    let work = ProfileIdentifiers.menuItem("NewWorkWindow?isDefaultProfile=false")
    check(work?.name == "Work" && work?.isDefault == false, "another profile's menu item")
    check(ProfileIdentifiers.menuItem("NewWindow WorksWindow?isDefaultProfile=false")?.name == "Window Works", "a name with Window in it")
    check(ProfileIdentifiers.menuItem("NewMy Work & Play=1?Window?isDefaultProfile=false")?.name == "My Work & Play=1?", "a name with spaces, &, = and ?")
    check(ProfileIdentifiers.menuItem("NewMy%20WorkWindow?isDefaultProfile=false")?.name == "My Work", "a percent-encoded name")
    check(ProfileIdentifiers.menuItem("NewWindow?isDefaultProfile=maybe") == nil, "an unknown flag")
    for other in ["NewPrivateWindow", "NewTab", "NewWindowSubmenuItem", "NewEmptyTabGroupMenuItem", "OpenLocation", ""] {
        check(ProfileIdentifiers.menuItem(other) == nil, "\(other) is no profile's item")
    }
    check(ProfileIdentifiers.menuItem(nil) == nil, "no identifier")

    let button = ProfileIdentifiers.toolbarButton("TabGroupPickerButton?Profile=Personal&Icon=person.fill")
    check(button?.name == "Personal" && button?.symbol == "person.fill", "toolbar button: name and symbol")
    let ampersand = ProfileIdentifiers.toolbarButton("TabGroupPickerButton?Profile=Work & Play&Icon=star.fill")
    check(ampersand?.name == "Work & Play" && ampersand?.symbol == "star.fill", "toolbar button: a name with &")
    let tricky = ProfileIdentifiers.toolbarButton("TabGroupPickerButton?Profile=A=B&Icon=C&Icon=bag.fill")
    check(tricky?.name == "A=B&Icon=C" && tricky?.symbol == "bag.fill", "toolbar button: the symbol is after the last &Icon=")
    check(ProfileIdentifiers.toolbarButton("TabGroupPickerButton?Profile=My%20Work&Icon=star.fill")?.name == "My Work", "toolbar button: percent-encoded name")
    let noIcon = ProfileIdentifiers.toolbarButton("TabGroupPickerButton?Profile=Personal")
    check(noIcon?.name == "Personal" && noIcon?.symbol == nil, "toolbar button without a symbol")
    check(ProfileIdentifiers.toolbarButton("TabGroupPickerButton?Profile") == nil, "Safari 26's button names no profile")
    check(ProfileIdentifiers.toolbarButton("SidebarButton") == nil, "another toolbar button")

    check(ProfileIdentifiers.sameName("My Work", "MyWork"), "a name without its spaces is the same")
    check(!ProfileIdentifiers.sameName("Work", "Personal"), "different names")
    check(ProfileIdentifiers.isBrowserWindow("SafariWindow?IsSecure=false&UUID=X") && !ProfileIdentifiers.isBrowserWindow("_NS:111"), "browser windows vs Settings")

    let parsed = ProfileIdentifiers.menuProfiles([
        ("NewPersonalWindow?isDefaultProfile=true", "N", 0),
        ("NewPersonalWindow?isDefaultProfile=false", "1", 3),
        ("SomethingElse", nil, nil),
        ("NewWorkWindow?isDefaultProfile=false", "2", 3),
    ])
    check(parsed.map(\.name) == ["Personal", "Personal", "Work"], "menu items in order, others skipped")
    check(parsed.map(\.hasNewWindowShortcut) == [true, false, false], "⌘N is only the item with N and no modifiers")
}

// MARK: - The menus in recorded trees

do {
    reads = []
    let bar = tree("safari-menubar-personal-window-front")
    guard case .profiles(let items)? = ProfileTree.newWindowMenu(in: bar) else {
        check(false, "File → New Window not found")
        exit(1)
    }
    check(items.map(\.profile.name) == ["Personal", "Personal", "Work"], "three profiles in Safari's order, got \(items.map(\.profile.name))")
    check(items.map(\.profile.isDefault) == [true, false, false], "the first is the default")
    check(items.map(\.profile.hasNewWindowShortcut) == [true, false, false], "⌘N on the default profile's item")
    check(items.map(\.node.identifier) == ["NewPersonalWindow?isDefaultProfile=true", "NewPersonalWindow?isDefaultProfile=false", "NewWorkWindow?isDefaultProfile=false"], "the items to press")
    check(!reads.contains { $0.contains("ApplicationMenu") || $0.contains("_NS:889") }, "only the File menu is read, not \(reads)")
    // Every File menu item's submenu is looked at (#40), but only one level down, and nothing else.
    let fileItems = bar.kids[2].kids[0].kids.count
    check(reads.count <= fileItems + 4, "reading the menu reads the File menu and its submenus only, took \(reads.count) for \(fileItems) items")
    check(!reads.contains { $0.hasPrefix("AXMenuItem#New") && $0.contains("?isDefaultProfile") }, "a profile's item's own children aren't read")

    let other = tree("safari-menubar-second-personal-window-front")
    if case .profiles(let items)? = ProfileTree.newWindowMenu(in: other) {
        check(items.map(\.profile.hasNewWindowShortcut) == [false, false, true], "⌘N moved to the third item")
    } else {
        check(false, "File → New Window not found in the second menu")
    }

    reads = []
    let manage = ProfileTree.manageProfilesItem(in: bar)
    check(manage?.identifier == "ManageProfilesMenuItem", "Safari → Manage Profiles… found")
    check(!reads.contains("AXMenu#SafariFileMenu"), "the File menu isn't read for it")

    // A menu bar with an extra item before File: still found, by identifier.
    let fileMenu = Node(role: "AXMenu", identifier: "SafariFileMenu", [
        Node(role: "AXMenuItem", identifier: "NewWindowSubmenuItem", [
            Node(role: "AXMenu", identifier: "NewWindowSubmenu", [
                Node(role: "AXMenuItem", identifier: "NewWorkWindow?isDefaultProfile=false", commandCharacter: "N", commandModifiers: 0),
                Node(role: "AXMenuItem", identifier: "NewHomeWindow?isDefaultProfile=true", commandCharacter: "0", commandModifiers: 3),
            ]),
        ]),
    ])
    let shifted = Node(role: "AXMenuBar", [
        Node(role: "AXMenuBarItem"), Node(role: "AXMenuBarItem", [Node(role: "AXMenu", identifier: "ApplicationMenu")]),
        Node(role: "AXMenuBarItem", [Node(role: "AXMenu", identifier: "SomeoneElsesMenu")]),
        Node(role: "AXMenuBarItem", [fileMenu]),
    ])
    if case .profiles(let items)? = ProfileTree.newWindowMenu(in: shifted) {
        check(items.map(\.profile.name) == ["Work", "Home"] && items[1].profile.isDefault, "File menu found away from its usual place")
    } else {
        check(false, "File menu away from its usual place not found")
    }

    // Safari without profiles: File → New Window is a plain item.
    let single = Node(role: "AXMenuBar", [
        Node(role: "AXMenuBarItem"), Node(role: "AXMenuBarItem"),
        Node(role: "AXMenuBarItem", [Node(role: "AXMenu", identifier: "SafariFileMenu", [
            Node(role: "AXMenuItem", identifier: "NewWindow", commandCharacter: "N", commandModifiers: 0),
        ])]),
    ])
    if case .singleProfile? = ProfileTree.newWindowMenu(in: single) {} else {
        check(false, "a File menu without the submenu means a single profile")
    }
    check(ProfileTree.newWindowMenu(in: Node(role: "AXMenuBar")) == nil, "no File menu: nothing read")

    // Pressing: the item at the profile's position, or the one with its name if the menu changed.
    let entries = items.map { ($0.node, $0.profile) }
    let work = SafariProfile(name: "Work", isDefault: false)
    check(ProfileTree.newWindowItem(for: work, at: 2, among: entries)?.identifier == "NewWorkWindow?isDefaultProfile=false", "Work's item by position")
    check(ProfileTree.newWindowItem(for: work, at: 1, among: entries)?.identifier == "NewWorkWindow?isDefaultProfile=false", "Work's item by name when its position changed")
    let second = SafariProfile(name: "Personal", isDefault: false)
    check(ProfileTree.newWindowItem(for: second, at: 1, among: entries)?.identifier == "NewPersonalWindow?isDefaultProfile=false", "the second Personal by position and flag")
    check(ProfileTree.newWindowItem(for: SafariProfile(name: "Gone", isDefault: false), at: 3, among: entries) == nil, "a deleted profile has no item")
    let defaultProfile = SafariProfile(name: "Personal", isDefault: true)
    check(ProfileTree.newWindowItem(for: defaultProfile, at: 1, among: entries)?.identifier == "NewPersonalWindow?isDefaultProfile=true", "the default profile by its flag, not the other Personal")
}

// MARK: - Profiles' items wherever Safari puts them, and the menu's shape for the log (#40)

/// A File menu (in a menu bar, at its usual place) with these items.
func fileMenuBar(_ items: [Node]) -> Node {
    Node(role: "AXMenuBar", [
        Node(role: "AXMenuBarItem"),
        Node(role: "AXMenuBarItem", [Node(role: "AXMenu", identifier: "ApplicationMenu")]),
        Node(role: "AXMenuBarItem", [Node(role: "AXMenu", identifier: "SafariFileMenu", items)]),
    ])
}
func item(_ identifier: String?, _ submenu: Node? = nil) -> Node {
    Node(role: "AXMenuItem", identifier: identifier, submenu.map { [$0] } ?? [])
}
func profileNames(_ result: ProfileTree.NewWindowMenu<Node>?) -> [String]? {
    guard case .profiles(let entries)? = result else { return nil }
    return entries.map { ($0.profile.isDefault ? "*" : "") + $0.profile.name }
}

do {
    let topLevel = fileMenuBar([
        item("NewHomeWindow?isDefaultProfile=true"), item("NewWorkWindow?isDefaultProfile=false"),
        item("NewPrivateWindow"), item("NewTab"), item("OpenLocation"),
    ])
    check(profileNames(ProfileTree.newWindowMenu(in: topLevel)) == ["*Home", "Work"], "two profiles as items of the File menu itself")

    let otherSubmenu = fileMenuBar([
        item("NewProfileWindowItem", Node(role: "AXMenu", identifier: "SomethingElse", [
            item("NewHomeWindow?isDefaultProfile=true"), item("NewWorkWindow?isDefaultProfile=false"),
        ])),
        item("NewPrivateWindow"),
    ])
    check(profileNames(ProfileTree.newWindowMenu(in: otherSubmenu)) == ["*Home", "Work"], "two profiles in a submenu with another identifier")

    let mixed = fileMenuBar([
        item("NewHomeWindow?isDefaultProfile=true"),
        item("NewWindowSubmenuItem", Node(role: "AXMenu", identifier: "NewWindowSubmenu", [item("NewWorkWindow?isDefaultProfile=false")])),
        item("NewTravelWindow?isDefaultProfile=false"),
    ])
    check(profileNames(ProfileTree.newWindowMenu(in: mixed)) == ["*Home", "Work", "Travel"], "items at both levels, in menu order")

    // Two profiles, as Safari 27.2 shows them: at the top of the File menu, no submenu (#40).
    let twoProfiles = tree("constructed-file-menu-two-profiles")
    if case .profiles(let entries)? = ProfileTree.newWindowMenu(in: twoProfiles) {
        check(entries.map(\.profile.name) == ["Personal", "Work"] && entries.map(\.profile.isDefault) == [true, false],
              "two profiles at the top of the File menu, the default first")
        check(entries.map(\.profile.hasNewWindowShortcut) == [false, true], "⌘N on the front window's profile, not on New Private Window (⇧⌘N)")
        let work = SafariProfile(name: "Work", isDefault: false)
        check(ProfileTree.newWindowItem(for: work, at: 1, among: entries.map { ($0.node, $0.profile) })?.identifier == "NewWorkWindow?isDefaultProfile=false",
              "Work's item to press")
    } else {
        check(false, "the two-profile File menu came up with no profiles")
    }
    let twoShape = ProfileTree.shape(of: ProfileTree.fileMenuItems(in: twoProfiles) ?? [])
    check(twoShape.hasPrefix("New<profile>Window?…, New<profile>Window?…, NewPrivateWindow, NewTab, NewEmptyTabGroupMenuItem, OpenFile"),
          "the two-profile menu's shape, got \(twoShape)")

    let plain = fileMenuBar([item("NewWindow"), item("NewPrivateWindow"), item("NewTab")])
    if case .singleProfile? = ProfileTree.newWindowMenu(in: plain) {} else { check(false, "one profile: a plain New Window item") }
    let emptySubmenu = fileMenuBar([item("NewWindowSubmenuItem", Node(role: "AXMenu", identifier: "NewWindowSubmenu")), item("NewTab")])
    if case .singleProfile? = ProfileTree.newWindowMenu(in: emptySubmenu) {} else { check(false, "a submenu with nothing in it: no profiles found") }

    // The shape for the log: identifiers cut at "?", no profile's name anywhere.
    let recorded = ProfileTree.fileMenuItems(in: tree("safari-menubar-personal-window-front")) ?? []
    let shape = ProfileTree.shape(of: recorded)
    check(shape.hasPrefix("NewWindowSubmenuItem [AXMenu NewWindowSubmenu: New<profile>Window?…, New<profile>Window?…, New<profile>Window?…], NewPrivateWindow, NewTab"),
          "the recorded menu's shape, got \(shape.prefix(160))")
    check(!shape.contains("Personal") && !shape.contains("Work") && !shape.contains("isDefaultProfile"), "no names in the shape")
    let odd = ProfileTree.shape(of: ProfileTree.fileMenuItems(in: fileMenuBar([
        item("NewSecretWindow"), item("NewSecretWindow?flag=1"), item("NewWindow"), item("NewPrivateWindow"), item(nil), item("OpenFile?x=Secret"),
    ])) ?? [])
    check(odd == "New<?>Window, New<?>Window?…, NewWindow, NewPrivateWindow, -, OpenFile?…", "anything shaped like a profile's item loses its name, got \(odd)")
}

// MARK: - Toolbars in recorded trees

do {
    func toolbar(_ name: String) -> ToolbarProfile {
        reads = []
        return ProfileTree.toolbarProfile(of: tree(name))
    }
    check(toolbar("window-personal-test-page") == .profile(name: "Personal", symbol: "person.fill"), "a Personal window")
    check(!reads.contains { $0.hasPrefix("AXOpaqueProviderGroup") || $0.hasPrefix("AXSplitGroup") || $0.hasPrefix("AXWebArea") },
          "the tab bar, the page and the area beside it aren't read: \(reads)")
    check(toolbar("window-work-new-window-start-page") == .profile(name: "Work", symbol: "graduationcap.fill"), "a Work window, right after it opened")
    check(toolbar("window-personal-minimized-real") == .profile(name: "Personal", symbol: "person.fill"), "a minimized window")
    check(toolbar("window-private") == .noProfileButton, "a private window has no profile button")
    check(toolbar("settings-profiles-general-tab") == .noProfileButton, "Settings has no profile button")
    check(toolbar("compact-window") == .profile(name: "", symbol: nil), "Safari 26's button names no profile")
    check(toolbar("compact-fullscreen") == .profile(name: "", symbol: nil), "in full screen the toolbar is inside a group")
    check(ProfileTree.toolbarProfile(of: Node(role: "AXWindow", [Node(role: "AXSplitGroup")])) == .unknown, "no toolbar: unknown, not private")
    // Made up, not recorded: the button inside a group of the toolbar, as the private window keeps
    // its sidebar button.
    let grouped = Node(role: "AXWindow", [Node(role: "AXToolbar", [
        Node(role: "AXGroup", [Node(role: "AXButton", identifier: "SidebarButton")]),
        Node(role: "AXGroup", [Node(role: "AXMenuButton", identifier: "TabGroupPickerButton?Profile=Work&Icon=bag.fill")]),
    ])])
    check(ProfileTree.toolbarProfile(of: grouped) == .profile(name: "Work", symbol: "bag.fill"), "a profile button inside a toolbar group")
}

// MARK: - Settings → Profiles in recorded trees

do {
    let general = tree("settings-profiles-general-tab")
    guard let pane = ProfileTree.profilesPane(in: general) else {
        check(false, "the Profiles pane not found")
        exit(1)
    }
    check(pane.identifier == "SafariProfilesPreferencesView", "the Profiles pane")
    let table = ProfileTree.profilesTable(in: pane)
    check(table?.children().filter { $0.role == "AXRow" }.count == 3, "one row per profile")
    let tabs = ProfileTree.profileTabs(in: pane)
    check(tabs.count == 2 && tabs[ProfileTree.extensionsTabIndex].title == "Extensions", "the Extensions tab is the second")
    let extensionsTab = tree("settings-profiles-extensions-tab")
    check(ProfileTree.profilesPane(in: extensionsTab).map { ProfileTree.profileTabs(in: $0).count } == 2, "the pane on its Extensions tab")
    check(ProfileTree.profilesPane(in: tree("settings-extensions-pane")) == nil, "Settings → Extensions isn't the Profiles pane")
    check(ProfileTree.profilesPane(in: tree("window-personal-test-page")) == nil, "a browser window isn't Settings")
}

// MARK: - Keeping the list up to date

let personalSymbol = "person.fill"
let secondSymbol = "person.lanyardcard.fill"
let workSymbol = "graduationcap.fill"
let keyB = ProfileKey(rawValue: "BBBBBBBB-0000-0000-0000-000000000000")
let keyW = ProfileKey(rawValue: "WWWWWWWW-0000-0000-0000-000000000000")
let keyX = ProfileKey(rawValue: "XXXXXXXX-0000-0000-0000-000000000000")

func menu(_ entries: [(String, Bool)]) -> [MenuProfile] {
    entries.map { MenuProfile(name: $0.0, isDefault: $0.1) }
}

let rememberedThree = [
    SafariProfile(name: "Personal", isDefault: true, symbol: personalSymbol),
    SafariProfile(name: "Personal", isDefault: false, symbol: secondSymbol, key: keyB),
    SafariProfile(name: "Work", isDefault: false, symbol: workSymbol, key: keyW),
]

do {
    let fresh = ProfileList.reconcile(remembered: [], menu: menu([("Personal", true), ("Personal", false), ("Work", false)]))
    check(fresh.map(\.name) == ["Personal", "Personal", "Work"], "first read: the menu's profiles")
    check(fresh.map(\.key) == [.defaultProfile, nil, nil], "the default profile's key is known; the others' aren't")
    check(fresh.allSatisfy { $0.symbol == nil }, "no symbols yet: the buttons show first letters")
    check(fresh[0].initial == "P" && SafariProfile(name: "work", isDefault: false).initial == "W", "first letters")

    let same = ProfileList.reconcile(remembered: rememberedThree, menu: menu([("Personal", true), ("Personal", false), ("Work", false)]))
    check(same == rememberedThree, "the same menu changes nothing")

    let deleted = ProfileList.reconcile(remembered: rememberedThree, menu: menu([("Personal", true), ("Work", false)]))
    check(deleted.map(\.id) == [rememberedThree[0].id, rememberedThree[2].id], "a deleted profile goes, the others keep their ids")
    check(deleted[1].key == keyW && deleted[1].symbol == workSymbol, "Work keeps its key and symbol at its new position")

    let added = ProfileList.reconcile(remembered: rememberedThree, menu: menu([("Personal", true), ("Personal", false), ("Work", false), ("Travel", false)]))
    check(Array(added.prefix(3)) == rememberedThree && added[3].name == "Travel" && added[3].symbol == nil && added[3].key == nil, "a new profile at the end")

    let renamed = ProfileList.reconcile(remembered: rememberedThree, menu: menu([("Personal", true), ("Personal", false), ("Office", false)]))
    check(renamed[2].id == rememberedThree[2].id && renamed[2].name == "Office", "a rename in place keeps the id")
    check(renamed[2].symbol == workSymbol && renamed[2].key == nil, "a renamed profile keeps its symbol but learns its key again")

    let reordered = ProfileList.reconcile(remembered: rememberedThree, menu: menu([("Personal", true), ("Work", false), ("Personal", false)]))
    check(reordered.map(\.id) == [rememberedThree[0].id, rememberedThree[2].id, rememberedThree[1].id], "a new order: each keeps its id by name")
    check(reordered[2].key == keyB, "the second Personal keeps its key")

    let swapped = ProfileList.reconcile(remembered: rememberedThree, menu: menu([("Personal", true), ("Work", false), ("Travel", false)]))
    check(swapped[1].id == rememberedThree[2].id && swapped[1].key == keyW, "deleted and added in one go: Work kept")
    check(swapped[2].key == nil && swapped[2].symbol == nil && swapped[2].id != rememberedThree[1].id, "the new profile doesn't inherit the deleted one's key or symbol")

    let single = ProfileList.reconcile(remembered: rememberedThree, menu: [MenuProfile(name: "", isDefault: true)])
    check(single.count == 1 && single[0].id == rememberedThree[0].id && single[0].key == .defaultProfile, "down to one profile: the default stays")

    var assigned = rememberedThree
    check(ProfileList.assign(keyX, to: assigned[2].id, in: &assigned) && assigned[2].key == keyX, "a new key for Work")
    check(ProfileList.assign(keyB, to: assigned[2].id, in: &assigned) && assigned[2].key == keyB && assigned[1].key == nil, "a key moves from the profile that had it")
    check(!ProfileList.assign(.defaultProfile, to: assigned[2].id, in: &assigned), "the default copy's key never goes to another profile")
    check(!ProfileList.assign(keyX, to: assigned[0].id, in: &assigned), "the default profile keeps its key")
}

// MARK: - Checking a read against open windows and live copies (#40)

extension Array {
    /// The element at `index`, or nil past the end, so a check fails rather than the checks crashing.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

do {
    let defaultID = rememberedThree[0].id, secondID = rememberedThree[1].id, workID = rememberedThree[2].id
    let all = menu([("Personal", true), ("Personal", false), ("Work", false)])
    let single = [MenuProfile(name: "", isDefault: true)]
    let workWindow = ToolbarProfile.profile(name: "Work", symbol: workSymbol)
    let secondWindow = ToolbarProfile.profile(name: "Personal", symbol: secondSymbol)
    let start = Date(timeIntervalSince1970: 1_000_000)
    func update(_ remembered: [SafariProfile], _ read: [MenuProfile], windows: [ToolbarProfile] = [], live: Set<ProfileKey> = [],
                missing: [UUID: Date] = [:], at: TimeInterval = 0, mayDrop: Bool = true) -> ProfileListUpdate {
        ProfileList.update(remembered, read: read, evidence: ProfileEvidence(toolbars: windows, liveKeys: live),
                           missingSince: missing, now: start.addingTimeInterval(at), mayDrop: mayDrop)
    }

    let full = update(rememberedThree, all, windows: [workWindow])
    check(full.profiles == rememberedThree && full.agrees, "a read that has every profile agrees")

    // What happened in #40: a read that found one profile, with a Work window open.
    let short = update(rememberedThree, single, windows: [workWindow], live: [.defaultProfile, keyB])
    check(short.profiles.map(\.id) == [defaultID, secondID, workID], "a short read takes no button away, and keeps the order")
    check(short.profiles[safe: 2]?.symbol == workSymbol && short.profiles[safe: 2]?.key == keyW && short.profiles[safe: 0]?.name == "Personal",
          "kept profiles keep their symbol and key, and the default its name")
    check(short.keptForWindows == [workID] && short.keptForCopies == [secondID] && !short.agrees, "kept for an open window and for a live copy; read again")
    check(short.missingSince.isEmpty && short.removed.isEmpty, "a profile something still shows isn't on its way out")

    // A deleted profile: nothing shows it, so it goes once two reads about a second apart agree.
    let deleted = menu([("Personal", true), ("Work", false)])
    let first = update(rememberedThree, deleted)
    check(first.profiles.map(\.id) == [defaultID, secondID, workID] && first.awaitingSecondRead == [secondID] && !first.agrees,
          "the first read that lacks it keeps it, and asks for a second")
    let soon = update(first.profiles, deleted, missing: first.missingSince, at: 0.5)
    check(soon.profiles.count == 3 && soon.awaitingSecondRead == [secondID], "half a second later is too soon to agree")
    let second = update(soon.profiles, deleted, missing: soon.missingSince, at: 1.5)
    check(second.profiles.map(\.id) == [defaultID, workID] && second.removed == [secondID] && second.agrees, "a second read a second later agrees: it goes")
    let starting = update(soon.profiles, deleted, missing: soon.missingSince, at: 1.5, mayDrop: false)
    check(starting.profiles.count == 3 && starting.removed.isEmpty, "not while Safari or Side Tabs is starting")
    let back = update(first.profiles, all, missing: first.missingSince, at: 1.5)
    check(back.profiles == rememberedThree && back.missingSince.isEmpty && back.agrees, "a read that has it again forgets it was missing")
    let stillLive = update(first.profiles, deleted, live: [keyB], missing: first.missingSince, at: 1.5)
    check(stillLive.profiles.count == 3 && stillLive.keptForCopies == [secondID], "while its copy is live, it stays, until the copy goes quiet")

    // From two profiles to one, where the menu changes shape.
    let two = [rememberedThree[0], rememberedThree[2]]
    let toOne = update(update(two, single).profiles, single, missing: update(two, single).missingSince, at: 1)
    check(toOne.profiles.map(\.id) == [defaultID] && toOne.profiles[safe: 0]?.name == "Personal", "two to one: Work goes after two reads, the default keeps its name")
    // And from one to two: a new profile shows at once.
    let toTwo = update([rememberedThree[0]], menu([("Personal", true), ("Travel", false)]))
    check(toTwo.profiles.map(\.name) == ["Personal", "Travel"] && toTwo.agrees, "one to two: the new profile at once")

    // Between two and three profiles Safari moves the items between the File menu's top level and a
    // submenu, both ways. Read from the trees, so the shapes are the ones the parser sees.
    func menuProfiles(_ name: String) -> [MenuProfile] {
        guard case .profiles(let entries)? = ProfileTree.newWindowMenu(in: tree(name)) else { return [] }
        return entries.map(\.profile)
    }
    let threeShape = menuProfiles("safari-menubar-personal-window-front")
    let twoShape = menuProfiles("constructed-file-menu-two-profiles")
    let twoKnown = [rememberedThree[0], rememberedThree[2]]
    let grown = update(twoKnown, threeShape)
    check(grown.profiles.map(\.name) == ["Personal", "Personal", "Work"] && grown.agrees, "two to three: the submenu's three, at once")
    check(grown.profiles[safe: 0]?.id == defaultID && grown.profiles[safe: 2]?.id == workID && grown.profiles[safe: 2]?.key == keyW,
          "the two known before keep their ids and keys")
    let shrinking = update(rememberedThree, twoShape)
    check(shrinking.profiles.count == 3 && shrinking.awaitingSecondRead == [secondID], "three to two: the top-level read lacks one, kept for a second read")
    let shrunk = update(shrinking.profiles, twoShape, missing: shrinking.missingSince, at: 1)
    check(shrunk.profiles.map(\.id) == [defaultID, workID] && shrunk.profiles[safe: 1]?.key == keyW && shrunk.agrees, "and then it goes; Work keeps its key")

    // A profiles.json left with one profile by an earlier build.
    let repaired = update([rememberedThree[0]], all)
    check(repaired.profiles.map(\.name) == ["Personal", "Personal", "Work"] && repaired.agrees, "a good read brings the others back")
    let fromWindows = update([rememberedThree[0]], single, windows: [workWindow, secondWindow, .profile(name: "Personal", symbol: personalSymbol), .noProfileButton])
    check(fromWindows.profiles.map(\.name) == ["Personal", "Work", "Personal"] && fromWindows.profiles[safe: 1]?.symbol == workSymbol && fromWindows.profiles[safe: 2]?.symbol == secondSymbol,
          "while the menu still comes up short, open windows bring their profiles back")
    check(fromWindows.addedFromWindows.count == 2 && !fromWindows.agrees, "and it's read again")
    let thenRead = update(fromWindows.profiles, all, windows: [workWindow])
    check(thenRead.profiles.count == 3 && thenRead.profiles[safe: 2]?.id == fromWindows.profiles[safe: 1]?.id, "the next good read keeps the ones windows brought back, in Safari's order")

    // A rename, its window's toolbar already saying the new name.
    let renamed = update(rememberedThree, menu([("Personal", true), ("Personal", false), ("Office", false)]), windows: [.profile(name: "Office", symbol: workSymbol)])
    check(renamed.profiles[safe: 2]?.id == workID && renamed.profiles[safe: 2]?.name == "Office" && renamed.agrees, "a rename keeps the profile, and agrees with its window")

    // A read without the default (half built) while the default's copy runs.
    let noDefault = update(rememberedThree, menu([("Personal", false), ("Work", false)]), live: [.defaultProfile])
    check(noDefault.profiles.first?.id == defaultID && noDefault.keptForCopies == [defaultID], "the default kept in its place for its live copy")
}

// MARK: - Which profile a window is in

func window(_ key: ProfileKey, _ active: String?, incognito: Bool = false) -> CopyWindow {
    CopyWindow(key: key, incognito: incognito, activeTitle: active)
}

do {
    let unknownSymbols = rememberedThree.map { profile -> SafariProfile in
        var copy = profile
        copy.symbol = nil
        if !copy.isDefault { copy.key = nil }
        return copy
    }
    let work = ToolbarProfile.profile(name: "Work", symbol: workSymbol)
    check(ProfileRules.resolve(work, windowTitle: "Work — A", profiles: unknownSymbols, copyWindows: []) == .profile(unknownSymbols[2].id), "a name only one profile has")
    check(ProfileRules.resolve(.profile(name: "Travel", symbol: nil), windowTitle: nil, profiles: unknownSymbols, copyWindows: []) == .unknownName, "a name the list doesn't have")
    check(ProfileRules.resolve(.noProfileButton, windowTitle: "A", profiles: unknownSymbols, copyWindows: []) == .noProfile, "a private window is no profile's")
    check(ProfileRules.resolve(.unknown, windowTitle: "A", profiles: unknownSymbols, copyWindows: []) == .noProfile, "an unread toolbar is no profile yet")

    let second = ToolbarProfile.profile(name: "Personal", symbol: secondSymbol)
    let first = ToolbarProfile.profile(name: "Personal", symbol: personalSymbol)
    check(ProfileRules.resolve(second, windowTitle: "Personal — A", profiles: unknownSymbols, copyWindows: []) == .ambiguous, "two Personal profiles, nothing known: can't tell")
    check(ProfileRules.resolve(second, windowTitle: "Personal — A", profiles: rememberedThree, copyWindows: []) == .profile(rememberedThree[1].id), "told apart by symbol")
    check(ProfileRules.resolve(first, windowTitle: "Personal — A", profiles: rememberedThree, copyWindows: []) == .profile(rememberedThree[0].id), "the default one by its symbol")

    var oneKnown = unknownSymbols
    oneKnown[0].symbol = personalSymbol
    check(ProfileRules.resolve(second, windowTitle: "Personal — A", profiles: oneKnown, copyWindows: []) == .profile(oneKnown[1].id), "by elimination: the other's symbol is known and differs")
    check(ProfileRules.resolve(first, windowTitle: "Personal — A", profiles: oneKnown, copyWindows: []) == .profile(oneKnown[0].id), "the known symbol")

    let defaultLists = [window(.defaultProfile, "A"), window(keyW, "B")]
    check(ProfileRules.resolve(first, windowTitle: "Personal — A", profiles: unknownSymbols, copyWindows: defaultLists) == .profile(unknownSymbols[0].id), "told apart by the default profile's copy listing the window")
    var keyed = unknownSymbols
    keyed[1].key = keyB
    check(ProfileRules.resolve(second, windowTitle: "Personal — C", profiles: keyed, copyWindows: [window(keyB, "C")]) == .profile(keyed[1].id), "told apart by a known key")
    check(ProfileRules.resolve(second, windowTitle: "Personal — C", profiles: keyed, copyWindows: [window(keyB, "C"), window(.defaultProfile, "C")]) == .ambiguous, "both list a window on the same page: can't tell")
    check(ProfileRules.resolve(second, windowTitle: "Personal — C", profiles: unknownSymbols, copyWindows: [window(.defaultProfile, "C", incognito: true)]) == .ambiguous, "a private window doesn't count for the default profile")

    check(ProfileRules.resolve(second, windowTitle: "Personal — A", profiles: unknownSymbols, copyWindows: [], newWindowShortcut: 1) == .profile(unknownSymbols[1].id), "⌘N as the last resort")
    check(ProfileRules.resolve(second, windowTitle: "Personal — A", profiles: unknownSymbols, copyWindows: [], newWindowShortcut: 2) == .ambiguous, "⌘N on another name's item doesn't decide")
    check(ProfileRules.resolve(second, windowTitle: "Personal — A", profiles: rememberedThree, copyWindows: [], newWindowShortcut: 0) == .profile(rememberedThree[1].id), "a known symbol wins over ⌘N")

    let single = [SafariProfile(name: "", isDefault: true)]
    check(ProfileRules.resolve(.profile(name: "", symbol: nil), windowTitle: "A", profiles: single, copyWindows: []) == .profile(single[0].id), "Safari without profiles: the one profile")
    check(ProfileRules.resolve(.profile(name: "", symbol: nil), windowTitle: "A", profiles: rememberedThree, copyWindows: []) == .unknownName, "a button that names no profile, with several: read the menu")
}

// MARK: - Which copy is a profile's

do {
    check(ProfileRules.fits(windowTitle: "Work — Google", profileName: "Work", activeTitle: "Google"), "a Work window")
    check(!ProfileRules.fits(windowTitle: "Personal — Google", profileName: "Work", activeTitle: "Google"), "another profile's window on the same page")
    check(ProfileRules.fits(windowTitle: "My Work — Google", profileName: "MyWork", activeTitle: "Google"), "a name written without spaces")
    check(ProfileRules.fits(windowTitle: "Work — Docs — Intro", profileName: "Work", activeTitle: "Docs — Intro"), "a page title with a dash in it")
    check(!ProfileRules.fits(windowTitle: "Work — Docs — Intro", profileName: "Work", activeTitle: "Intro"), "a shorter page title doesn't fit")
    check(!ProfileRules.fits(windowTitle: "Work — ", profileName: "Work", activeTitle: ""), "no page title: nothing fits")
    check(!ProfileRules.fits(windowTitle: nil, profileName: "Work", activeTitle: "A"), "no window title: nothing fits")
    check(ProfileRules.fits(windowTitle: "Google", profileName: "", activeTitle: "Google"), "Safari without profiles")

    var profiles = rememberedThree
    profiles[1].key = nil
    profiles[2].key = nil
    check(ProfileRules.keyToLearn(for: profiles[2], windowTitle: "Work — A", in: [window(keyW, "A"), window(keyB, "B")], profiles: profiles) == keyW, "the one copy listing the window")
    check(ProfileRules.keyToLearn(for: profiles[2], windowTitle: "Work — A", in: [window(keyW, "A"), window(keyX, "A")], profiles: profiles) == nil, "two copies list it: nothing learned")
    check(ProfileRules.keyToLearn(for: profiles[2], windowTitle: "Work — A", in: [window(keyW, "B")], profiles: profiles) == nil, "no copy lists it (off, or not reported yet)")
    check(ProfileRules.keyToLearn(for: profiles[1], windowTitle: "Personal — A", in: [window(.defaultProfile, "A")], profiles: profiles) == nil, "the default copy is never another profile's")
    check(ProfileRules.keyToLearn(for: profiles[0], windowTitle: "Personal — A", in: [window(keyB, "A")], profiles: profiles) == nil, "the default profile's copy sends no UUID")
    check(ProfileRules.keyToLearn(for: profiles[0], windowTitle: "Personal — A", in: [window(.defaultProfile, "A")], profiles: profiles) == nil, "already known")
    check(ProfileRules.keyToLearn(for: profiles[1], windowTitle: "Personal — A", in: [window(.defaultProfile, "A"), window(keyB, "A")], profiles: profiles) == keyB,
          "the other Personal's copy, with the default's (known to be the default profile's) on the same page")
    check(ProfileRules.keyToLearn(for: profiles[1], windowTitle: "Personal — A", in: [window(keyB, "A", incognito: true)], profiles: profiles) == nil, "private windows don't count")
    var withWork = profiles
    withWork[2].key = keyW
    check(ProfileRules.keyToLearn(for: withWork[1], windowTitle: "Personal — A", in: [window(keyW, "A")], profiles: withWork) == nil, "a copy known to be another profile's isn't learned")
}

// MARK: - When Side Tabs counts as off

do {
    let profiles = rememberedThree
    let work = profiles[2]
    func copy(_ key: ProfileKey, live: Bool = true, lists: Bool = false) -> CopyState {
        CopyState(key: key, isLive: live, reportsWindow: lists)
    }
    check(!ProfileRules.isOff(work, profiles: profiles, windowOpenFor: 1, copies: []), "not before its window has been open 2 s")
    check(ProfileRules.isOff(work, profiles: profiles, windowOpenFor: 2.5, copies: []), "no copy at all: off")
    check(!ProfileRules.isOff(work, profiles: profiles, windowOpenFor: 60, copies: [copy(keyW)]), "its copy is sending heartbeats: on, even if it missed the window")
    check(ProfileRules.isOff(work, profiles: profiles, windowOpenFor: 60, copies: [copy(keyW, live: false, lists: true)]), "its copy went quiet (#31): off, whatever its last snapshot says")
    check(ProfileRules.isOff(work, profiles: profiles, windowOpenFor: 60, copies: [copy(.defaultProfile), copy(keyB)]), "only other profiles' copies: off")
    check(ProfileRules.isOff(work, profiles: profiles, windowOpenFor: 60, copies: [copy(keyB, lists: true)]), "a copy known to be another profile's on the same page doesn't count")
    check(!ProfileRules.isOff(work, profiles: profiles, windowOpenFor: 60, copies: [copy(keyX, lists: true)]), "a copy no profile is known to have lists the window: on")
    check(ProfileRules.isOff(work, profiles: profiles, windowOpenFor: 60, copies: [copy(keyX)]), "a copy no profile is known to have, not listing it, when the profile's own copy is known: off")

    var unknownKey = profiles
    unknownKey[2].key = nil
    check(!ProfileRules.isOff(unknownKey[2], profiles: unknownKey, windowOpenFor: 60, copies: [copy(.defaultProfile), copy(keyX)]), "its copy isn't known: a live copy no profile has could be it")
    check(ProfileRules.isOff(unknownKey[2], profiles: unknownKey, windowOpenFor: 60, copies: [copy(.defaultProfile), copy(keyB)]), "its copy isn't known, and every live copy is another profile's: off")
    check(ProfileRules.isOff(unknownKey[2], profiles: unknownKey, windowOpenFor: 60, copies: [copy(keyX, live: false)]), "a quiet copy doesn't keep it on")

    let defaultProfile = profiles[0]
    check(!ProfileRules.isOff(defaultProfile, profiles: profiles, windowOpenFor: 60, copies: [copy(.defaultProfile)]), "the default profile's copy is live: on")
    check(ProfileRules.isOff(defaultProfile, profiles: profiles, windowOpenFor: 60, copies: [copy(keyB), copy(keyW)]), "the default profile without its copy: off")

    // What counts as listing the window: private windows don't, for the default profile.
    let listing = ProfileRules.copiesListing(windowTitle: "Personal — A", profileName: "Personal", in: [window(.defaultProfile, "A", incognito: true)])
    check(listing.isEmpty, "the default copy's private window doesn't list a Personal window")
}

// MARK: - Which window a switch brings forward

do {
    let p1 = UUID(), p2 = UUID()
    func facts(_ number: Int, _ profile: ProfileResolution, minimized: Bool = false) -> WindowFacts {
        WindowFacts(number: number, profile: profile, isMinimized: minimized)
    }
    let windows = [facts(1, .profile(p1)), facts(2, .profile(p2)), facts(3, .profile(p2))]
    check(ProfileRules.switchTarget(for: p2, among: windows)?.number == 2, "the profile's frontmost window")
    check(ProfileRules.switchTarget(for: p1, among: windows)?.number == 1, "the docked window counts, when it's the profile's")
    check(ProfileRules.switchTarget(for: p2, among: [facts(2, .profile(p2), minimized: true), facts(3, .profile(p2))])?.number == 3, "a window that isn't minimized first")
    check(ProfileRules.switchTarget(for: p2, among: [facts(1, .profile(p1)), facts(2, .profile(p2), minimized: true)])?.number == 2, "a minimized one if it has no other")
    check(ProfileRules.switchTarget(for: p2, among: [facts(1, .profile(p1)), facts(4, .noProfile), facts(5, .ambiguous)]) == nil, "no window of its own: a new one")
}

// MARK: - profiles.json across a restart

do {
    let folder = FileManager.default.temporaryDirectory.appending(path: "profile-checks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "profiles.json")
    check(ProfilesFile.load(from: url).isEmpty, "no file: no profiles")
    do {
        try ProfilesFile.save(rememberedThree, to: url)
    } catch {
        check(false, "saving failed: \(error)")
    }
    let loaded = ProfilesFile.load(from: url)
    check(loaded == rememberedThree, "names, symbols, order, default flag, keys and ids come back")
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    check(text.contains("\"key\" : \"default\"") && text.contains("\"key\" : \"\(keyW.rawValue)\""), "keys are saved as plain strings")
    check(ProfileList.reconcile(remembered: loaded, menu: menu([("Personal", true), ("Personal", false), ("Work", false)])) == rememberedThree,
          "after a restart, the same menu keeps everything")
    try? Data("not json".utf8).write(to: url)
    check(ProfilesFile.load(from: url).isEmpty, "a damaged file: no profiles, nothing breaks")
}

// MARK: - Where the buttons go in the bottom bar, and when the dropdown takes over (#39)

do {
    // Settings → Width: 180 to 420 points, 260 by default (AppSettings.widthRange and its registered default).
    let narrowest = ProfileBarLayout.barWidth(sidebarWidth: 180)
    let standard = ProfileBarLayout.barWidth(sidebarWidth: 260)
    let widest = ProfileBarLayout.barWidth(sidebarWidth: 420)
    check(narrowest == 164 && standard == 244 && widest == 404, "the bar is the sidebar less its insets")

    // Closed Tabs on the left; on the right the +, with the Settings gear a row up, over it (#43). If the gear ever
    // moved beside the +, the right end would widen and the counts below would drop.
    let side = ProfileBarLayout.sideButtonWidth
    let trailing = ProfileBarLayout.trailingWidth
    check(trailing == side, "the gear above the + leaves the right end one button wide (#43)")
    func fitting(_ bar: CGFloat, leading: CGFloat) -> Int {
        ProfileBarLayout.buttonsFitting(in: ProfileBarLayout.room(barWidth: bar, leading: leading, trailing: trailing))
    }
    check(fitting(narrowest, leading: side) == 3, "3 buttons fit at the narrowest, got \(fitting(narrowest, leading: side))")
    check(fitting(standard, leading: side) == 6, "6 fit at the default width, got \(fitting(standard, leading: side))")
    check(fitting(widest, leading: side) == 12, "12 fit at the widest, got \(fitting(widest, leading: side))")
    for bar in [narrowest, standard, widest] {
        check(fitting(bar, leading: 0) == fitting(bar, leading: side), "without Closed Tabs, as many fit: the + on the other side is as wide")
    }
    check(fitting(standard, leading: 60) < fitting(standard, leading: side), "a wider item at one end leaves less room on both sides")
    check(ProfileBarLayout.room(barWidth: standard, leading: 0, trailing: 0) == standard, "with nothing at the ends, the whole bar")

    // The room is the same on both sides: the buttons are centred in the sidebar, clear of both ends.
    for (bar, leading) in [(narrowest, side), (standard, 0), (standard, side), (widest, 0)] {
        let count = fitting(bar, leading: leading)
        let width = ProfileBarLayout.buttonsWidth(count: count)
        let place = ProfileBarLayout.centred(width: width, barWidth: bar)
        check(abs(place.minX - (bar - place.maxX)) < 0.001, "equal room on both sides at \(bar), \(count) buttons")
        check(place.minX >= max(leading, trailing) + ProfileBarLayout.gap - 0.001, "the buttons clear the ends at \(bar)")
        check(ProfileBarLayout.buttonsWidth(count: count + 1) > ProfileBarLayout.room(barWidth: bar, leading: leading, trailing: trailing),
              "and one more wouldn't fit at \(bar)")
    }
    check(ProfileBarLayout.buttonsWidth(count: 1) == 26 && ProfileBarLayout.buttonsWidth(count: 3) == 82 && ProfileBarLayout.buttonsWidth(count: 0) == 0,
          "buttons with the spacing between them")
    check(ProfileBarLayout.buttonsFitting(in: 25) == 0 && ProfileBarLayout.buttonsFitting(in: 26) == 1 && ProfileBarLayout.buttonsFitting(in: 54) == 2,
          "a button fits only whole")

    // When the dropdown takes over.
    func middle(_ count: Int, _ bar: CGFloat, leading: CGFloat = 0) -> ProfileBarLayout.Middle {
        ProfileBarLayout.middle(profileCount: count, barWidth: bar, leading: leading, trailing: trailing)
    }
    check(middle(1, standard) == .nothing && middle(0, standard) == .nothing, "one profile: only the + shows")
    check(middle(2, narrowest) == .buttons && middle(3, narrowest) == .buttons, "at the narrowest, 3 profiles are buttons")
    check(middle(4, narrowest) == .dropdown(maxWidth: 100), "and a 4th turns them into a dropdown, as wide as the room")
    check(middle(6, standard, leading: side) == .buttons && middle(7, standard, leading: side) == .dropdown(maxWidth: 180), "at the default width, the 7th")
    check(middle(12, widest) == .buttons && middle(13, widest) == .dropdown(maxWidth: 340), "at the widest, the 13th")
    check(middle(4, narrowest) == .dropdown(maxWidth: 100) && middle(4, standard) == .buttons, "widening the sidebar turns the dropdown back into buttons")
    if case .dropdown(let maxWidth) = middle(9, standard) {
        let place = ProfileBarLayout.centred(width: maxWidth, barWidth: standard)
        check(abs(place.minX - (standard - place.maxX)) < 0.001 && place.minX >= trailing + ProfileBarLayout.gap - 0.001, "the dropdown is centred in the same room")
    }
}

if failures > 0 {
    print("\(failures) profile check(s) failed")
    exit(1)
}
print("profile checks passed")
