import Foundation

// Checks for "Minimize other profiles' windows" (#42): the current profile, which windows a change of profile
// minimizes and which come back, in what order, which window a switch brings forward, the list of windows Side
// Tabs minimized, saving it and matching it after a restart, and when a click on Safari's Dock icon opens a
// window in the current profile. No Safari involved: these are the rules in MinimizeRules.swift and
// ProfileRules.switchTarget, which WindowMinimizer, ProfileSwitcher and MinimizeOtherProfiles carry out.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

let home = UUID()
let work = UUID()
let school = UUID()

func window(_ number: Int, _ profile: ProfileResolution, uuid: String? = nil, minimized: Bool = false, fullScreen: Bool = false, shown: Bool = true) -> ProfileWindow {
    ProfileWindow(number: number, uuid: uuid ?? "UUID-\(number)", profile: profile, isMinimized: minimized, isFullScreen: fullScreen, isOnShownSpace: shown)
}

// MARK: - The current profile

do {
    check(MinimizeRules.currentProfile(nil, front: .profile(home), onShownSpace: true) == home, "the first profile window in front makes its profile current")
    check(MinimizeRules.currentProfile(home, front: .profile(work), onShownSpace: true) == work, "another profile's window in front makes that profile current")
    check(MinimizeRules.currentProfile(home, front: .noProfile, onShownSpace: true) == home, "a private window doesn't change it: the profile you were in stays open behind it")
    check(MinimizeRules.currentProfile(home, front: .unknownName, onShownSpace: true) == home, "nor a window of a profile the list doesn't have")
    check(MinimizeRules.currentProfile(home, front: .ambiguous, onShownSpace: true) == home, "nor one whose profile can't be told apart")
    check(MinimizeRules.currentProfile(nil, front: .noProfile, onShownSpace: true) == nil, "with only a private window in front, there's no current profile yet")
    check(MinimizeRules.currentProfile(home, front: .profile(work), onShownSpace: false) == home,
          "nor a window on a desktop that isn't shown (Safari's next window after a close can be one): close means close")
}

// MARK: - Which windows a change minimizes

do {
    let windows = [
        window(1, .profile(work)),                     // the target, in front
        window(2, .profile(home)),                     // the window left behind
        window(3, .noProfile),                         // private
        window(4, .profile(home), fullScreen: true),   // full screen: macOS can't minimize it
        window(5, .profile(home)),
        window(6, .unknownName),
        window(7, .ambiguous),
        window(8, .profile(school)),                   // opened while Side Tabs wasn't running, say
        window(9, .profile(home), shown: false),       // on a desktop that isn't shown
        window(10, .profile(work)),                    // the new profile's other window
        window(11, .profile(home), minimized: true),   // the user minimized it
    ]
    let plan = MinimizeRules.plan(current: work, left: home, front: 1, windows: windows, list: MinimizedList())
    check(plan.minimize == [2, 5, 8], "every other profile's open window is minimized, front to back")
    check(!plan.minimize.contains(1), "never the target of the change")
    check(!plan.minimize.contains(3), "never a private window")
    check(!plan.minimize.contains(4), "never a full-screen window")
    check(!plan.minimize.contains(6) && !plan.minimize.contains(7), "never a window whose profile can't be told")
    check(!plan.minimize.contains(9), "never a window on a desktop that isn't shown")
    check(!plan.minimize.contains(10), "never the current profile's own windows")
    check(!plan.minimize.contains(11), "nor a window that's minimized already")
    check(plan.usedLast == [2, 8], "the frontmost window of each profile left behind is noted as used last")

    // The front window is protected whatever it is.
    let privateFront = MinimizeRules.plan(current: work, left: nil, front: 3, windows: windows, list: MinimizedList())
    check(privateFront.minimize == [2, 5, 8], "with a private window in front, the other profiles' windows are minimized behind it")
    let noFront = MinimizeRules.plan(current: work, left: nil, front: nil, windows: windows, list: MinimizedList())
    check(noFront.minimize.contains(2) && !noFront.minimize.contains(1), "with no window in front, the current profile's windows still stay")

    // A stray window of a profile left earlier doesn't take the mark from the one noted then.
    var list = MinimizedList()
    list.add(20, uuid: nil, profile: school, usedLast: true)
    let stray = MinimizeRules.plan(current: work, left: home, front: 1, windows: windows + [window(20, .profile(school), minimized: true)], list: list)
    check(stray.usedLast == [2], "a profile left earlier keeps the window noted then; only the profile just left gets a new one")
}

// MARK: - Which windows come back, in what order, and which one is in front

do {
    var list = MinimizedList()
    list.add(2, uuid: nil, profile: home, usedLast: false)
    list.add(3, uuid: nil, profile: home, usedLast: true)
    list.add(4, uuid: nil, profile: home, usedLast: false)
    list.add(5, uuid: nil, profile: work, usedLast: true)
    let windows = [
        window(1, .profile(work)),
        window(2, .profile(home), minimized: true),
        window(3, .profile(home), minimized: true),
        window(4, .profile(home), minimized: true),
        window(5, .profile(work), minimized: true),
        window(6, .profile(home), minimized: true),    // the user minimized it: not on the list
    ]
    // Another change (a Dock tile, say): the window the user picked, 2, is in front already.
    var picked = windows
    picked[1] = window(2, .profile(home))
    let afterChange = MinimizeRules.plan(current: home, left: work, front: 2, windows: picked, list: MinimizeRules.reconciled(list, with: picked))
    check(afterChange.restore == [4, 3], "the rest come back behind the window picked, back to front, the one used last at the end")
    check(!afterChange.restore.contains(6), "a window the user minimized stays minimized")
    check(afterChange.minimize == [1], "and the profile left behind is minimized")

    // A button switch: the switcher brings the window used last into the docked spot first.
    let facts = windows.map { WindowFacts(number: $0.number, profile: $0.profile, isMinimized: $0.isMinimized) }
    let target = ProfileRules.switchTarget(for: home, among: facts, usedLast: list.usedLast(in: home), listed: list.numbers)
    check(target?.number == 3, "a switch brings forward the window used last")
    var switched = windows
    switched[2] = window(3, .profile(home))
    let afterSwitch = MinimizeRules.plan(current: home, left: work, front: 3, windows: switched, list: list)
    check(afterSwitch.restore == [4, 2], "the profile's other windows come back after it, behind it")
    check(!afterSwitch.restore.contains(3), "the front window isn't brought back twice")
    check(!afterSwitch.restore.contains(5), "another profile's windows on the list stay minimized")

    // A window on the list that closed, or that the user brought back, isn't brought back.
    let gone = MinimizeRules.plan(current: home, left: work, front: 3, windows: switched.filter { $0.number != 4 }, list: list)
    check(gone.restore == [2], "a window that closed meanwhile isn't brought back")
}

// MARK: - Which window a switch brings forward

do {
    func facts(_ number: Int, _ profile: ProfileResolution, minimized: Bool = false) -> WindowFacts {
        WindowFacts(number: number, profile: profile, isMinimized: minimized)
    }
    let all = [
        facts(1, .profile(work)),
        facts(2, .profile(home), minimized: true),   // on the list
        facts(3, .profile(home), minimized: true),   // on the list, used last
        facts(4, .profile(home), minimized: true),   // the user's
    ]
    check(ProfileRules.switchTarget(for: home, among: all + [facts(5, .profile(home))], usedLast: 3, listed: [2, 3])?.number == 5,
          "1. a window of the profile that's open")
    check(ProfileRules.switchTarget(for: home, among: all, usedLast: 3, listed: [2, 3])?.number == 3, "2. the window noted as used last")
    check(ProfileRules.switchTarget(for: home, among: all, usedLast: nil, listed: [2, 3])?.number == 2, "3. another window on Side Tabs' list")
    check(ProfileRules.switchTarget(for: home, among: all, usedLast: 9, listed: [2, 3])?.number == 2, "a window noted as used last that's gone doesn't count")
    check(ProfileRules.switchTarget(for: home, among: [facts(1, .profile(work)), facts(4, .profile(home), minimized: true)], usedLast: nil, listed: [])?.number == 4,
          "4. a window the user minimized, when the profile has no other")
    check(ProfileRules.switchTarget(for: home, among: [facts(1, .profile(work)), facts(4, .profile(home), minimized: true), facts(2, .profile(home), minimized: true)],
                                    usedLast: nil, listed: [2])?.number == 2,
          "not while the profile has a window on the list")
    check(ProfileRules.switchTarget(for: school, among: all, usedLast: nil, listed: [2, 3]) == nil, "no window at all: a new one is opened")
    check(ProfileRules.switchTarget(for: home, among: [facts(2, .profile(home), minimized: true), facts(6, .profile(home))])?.number == 6,
          "with the setting off (an empty list), as before: the frontmost open window, else a minimized one")
}

// MARK: - The list

do {
    var list = MinimizedList()
    list.add(2, uuid: "A", profile: home, usedLast: true)
    list.add(3, uuid: "B", profile: home, usedLast: true)
    check(list.usedLast(in: home) == 3 && list.windows.filter(\.usedLast).count == 1, "a profile has one window used last: the newest mark wins")
    list.add(4, uuid: "C", profile: work, usedLast: false)
    check(list.usedLast(in: work) == nil, "a profile with none noted has none")
    list.add(4, uuid: "C", profile: work, usedLast: true)
    check(list.windows.filter { $0.number == 4 }.count == 1, "a window is on the list once")

    let windows = [
        window(2, .profile(home)),                     // brought back by the user
        window(3, .profile(home), minimized: true),
        // 4 closed
    ]
    let reconciled = MinimizeRules.reconciled(list, with: windows)
    check(reconciled.numbers == [3], "a window comes off the list when it's brought back or closed")
    check(!MinimizeRules.reconciled(list, with: windows).contains(2), "brought back by the user: if they minimize it again, it's theirs")

    // While its animation plays, Safari may still report a window the way it was.
    let now = Date()
    let reported = [window(5, .profile(work)), window(6, .profile(home), minimized: true)]
    let inFlight = [5: WindowInFlight(minimized: true, at: now.addingTimeInterval(-0.2)), 6: WindowInFlight(minimized: false, at: now.addingTimeInterval(-0.2))]
    let settled = MinimizeRules.settled(reported, inFlight: inFlight, now: now)
    check(settled[0].isMinimized && !settled[1].isMinimized, "a window just minimized counts as minimized, and one just brought back as open")
    var flying = MinimizedList()
    flying.add(5, uuid: nil, profile: work, usedLast: false)
    check(MinimizeRules.reconciled(flying, with: settled).contains(5), "so a window still on its way into the Dock stays on the list")
    let later = MinimizeRules.settled(reported, inFlight: inFlight, now: now.addingTimeInterval(MinimizeRules.animationAllowance))
    check(!later[0].isMinimized, "once the animation is long over, what Safari says goes: a window that didn't minimize comes off, and the next change tries again")

    // Turning the setting off brings back exactly the list.
    var off = MinimizedList()
    off.add(2, uuid: nil, profile: home, usedLast: false)
    off.add(3, uuid: nil, profile: work, usedLast: true)
    off.add(4, uuid: nil, profile: school, usedLast: false)
    let offWindows = [
        window(1, .profile(home)),
        window(2, .profile(home), minimized: true),
        window(3, .profile(work), minimized: true),
        window(5, .profile(work), minimized: true),    // the user's
        window(6, .noProfile, minimized: true),        // the user's
        // 4 closed
    ]
    check(MinimizeRules.restoreAll(off, windows: offWindows) == [3, 2], "turning it off brings back the list's windows, whatever their profile, back to front")
    check(!MinimizeRules.restoreAll(off, windows: offWindows).contains(5), "and no window the user minimized")
}

// MARK: - Saving the list, and matching it after a restart

do {
    var list = MinimizedList()
    list.add(10, uuid: "U-10", profile: home, usedLast: true)
    list.add(11, uuid: "U-11", profile: home, usedLast: false)
    list.add(12, uuid: "U-12", profile: school, usedLast: true)

    let folder = FileManager.default.temporaryDirectory.appending(path: "side-tabs-minimize-checks-\(UUID().uuidString)")
    let url = folder.appending(path: "minimized-windows.json")
    let file = MinimizedWindowsFile(safariProcessIdentifier: 4242, currentProfile: work, windows: list.windows)
    do {
        try MinimizedWindowsFile.save(file, to: url)
        check(MinimizedWindowsFile.load(from: url) == file, "the file keeps Safari's process ID, the current profile and the list")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let entry = (json["windows"] as? [[String: Any]])?.first ?? [:]
        check(Set(json.keys) == ["safariProcessIdentifier", "currentProfile", "windows"] && Set(entry.keys) == ["number", "uuid", "profile", "usedLast"],
              "and nothing else: no titles, names or URLs")
    } catch {
        check(false, "saving the list: \(error)")
    }
    try? FileManager.default.removeItem(at: folder)
    check(MinimizedWindowsFile.load(from: url) == nil, "no file: nothing saved")
    check(MinimizedWindowsFile.defaultURL.lastPathComponent == "minimized-windows.json"
          && MinimizedWindowsFile.defaultURL.deletingLastPathComponent() == ProfilesFile.defaultURL.deletingLastPathComponent(),
          "it's beside profiles.json")

    // The same Safari: window numbers still apply.
    let same = MinimizeRules.matched(list, sameSafari: true, windows: [
        window(10, .profile(home), uuid: "U-10", minimized: true),
        window(11, .profile(home), uuid: "U-11"),             // brought back meanwhile
        window(13, .profile(work), uuid: "U-13"),
        // 12 closed meanwhile
    ], current: work)
    check(same.numbers == [10] && same.usedLast(in: home) == 10, "for the same Safari the list still applies; windows that closed or came back drop off")

    // After Safari restarted, window numbers are new; the UUIDs survived.
    let byUUID = MinimizeRules.matched(list, sameSafari: false, windows: [
        window(50, .profile(work), uuid: "U-50"),
        window(51, .profile(home), uuid: "U-10", minimized: true),
        window(52, .profile(home), uuid: "U-11", minimized: true),
        window(53, .profile(home), uuid: "U-99", minimized: true),   // the user's
        window(54, .profile(school), uuid: "U-12"),                  // Safari reopened it open
    ], current: work)
    check(byUUID.numbers == [51, 52], "after a restart the list is matched by UUID, with the new window numbers")
    check(byUUID.usedLast(in: home) == 51, "keeping which window was used last")
    check(!byUUID.contains(53), "a window the user minimized stays theirs")
    check(!byUUID.contains(54), "and one Safari reopened open isn't on the list: the next sweep minimizes it")

    // The UUIDs didn't survive: every minimized window of another profile counts as Side Tabs'.
    let fallback = MinimizeRules.matched(list, sameSafari: false, windows: [
        window(60, .profile(work), uuid: "N-60"),
        window(61, .profile(home), uuid: "N-61", minimized: true),
        window(62, .profile(school), uuid: "N-62", minimized: true),
        window(63, .profile(work), uuid: "N-63", minimized: true),   // the current profile's: the user's
        window(64, .noProfile, uuid: "N-64", minimized: true),       // private
        window(65, .ambiguous, uuid: "N-65", minimized: true),
    ], current: work)
    check(fallback.numbers == [61, 62], "with no UUID surviving, every minimized window of a profile other than the current one counts as Side Tabs'")
    check(fallback.windows.first { $0.number == 62 }?.profile == school, "with its own profile")
    check(MinimizeRules.matched(list, sameSafari: false, windows: [window(61, .profile(home), minimized: true)], current: nil).isEmpty,
          "not before the current profile is known")
    check(MinimizeRules.matched(MinimizedList(), sameSafari: false, windows: [window(61, .profile(home), minimized: true)], current: work).isEmpty,
          "nothing saved: every minimized window is the user's")
}

// MARK: - A window's UUID

do {
    check(ProfileIdentifiers.windowUUID("SafariWindow?IsSecure=false&UUID=5F7A94A6-9600-4937-A88A-3F3311F82723") == "5F7A94A6-9600-4937-A88A-3F3311F82723",
          "the UUID from a recorded browser window's identifier")
    check(ProfileIdentifiers.windowUUID("SafariWindow?IsSecure=true&UUID=12A760F3-7749-4034-A4A5-81D08A27F7CC") == "12A760F3-7749-4034-A4A5-81D08A27F7CC",
          "whatever IsSecure says")
    check(ProfileIdentifiers.windowUUID("SafariWindow?UUID=AB&IsSecure=false") == "AB", "in any order")
    check(ProfileIdentifiers.windowUUID("SafariWindow") == nil && ProfileIdentifiers.windowUUID("SafariWindow?IsSecure=false&UUID=") == nil,
          "none when there's none")
    check(ProfileIdentifiers.windowUUID("_NS:111") == nil && ProfileIdentifiers.windowUUID(nil) == nil, "and none for Settings")
}

// MARK: - The Dock icon

do {
    let noneOpen = [
        window(1, .profile(home), minimized: true),
        window(2, .profile(work), minimized: true),
        window(3, .noProfile),
    ]
    check(DockIconRule.applies(isOn: true, current: work, windows: noneOpen), "it applies while the current profile has no open window")
    check(DockIconRule.applies(isOn: true, current: work, windows: []), "including when Safari has no window at all")
    check(DockIconRule.applies(isOn: true, current: work, windows: noneOpen + [window(4, .profile(work), shown: false)]),
          "a window on a desktop that isn't shown doesn't count as open")
    check(!DockIconRule.applies(isOn: true, current: work, windows: noneOpen + [window(4, .profile(work))]), "not while it has one")
    check(!DockIconRule.applies(isOn: true, current: work, windows: noneOpen + [window(4, .profile(work), fullScreen: true, shown: true)]),
          "a full-screen window on the desktop shown is open")
    check(!DockIconRule.applies(isOn: false, current: work, windows: noneOpen), "never with the setting off")
    check(!DockIconRule.applies(isOn: true, current: nil, windows: noneOpen), "nor before there's a current profile")

    let click = Date()
    check(DockIconRule.broughtByClick(windowProfile: .profile(home), current: work, clickAt: click, windowAt: click.addingTimeInterval(0.4)),
          "another profile's window coming within a second of the click counts")
    check(DockIconRule.broughtByClick(windowProfile: .profile(home), current: work, clickAt: click, windowAt: click.addingTimeInterval(-0.2)),
          "and so does one reported just before the click")
    check(!DockIconRule.broughtByClick(windowProfile: .profile(home), current: work, clickAt: click, windowAt: click.addingTimeInterval(1.5)),
          "not a window that comes later")
    check(!DockIconRule.broughtByClick(windowProfile: .profile(work), current: work, clickAt: click, windowAt: click.addingTimeInterval(0.4)),
          "only another profile's window: the current profile's own (minimized with ⌘M, say) is what the click should bring")
    check(!DockIconRule.broughtByClick(windowProfile: .noProfile, current: work, clickAt: click, windowAt: click.addingTimeInterval(0.4)),
          "never a private window")
    check(!DockIconRule.broughtByClick(windowProfile: .unknownName, current: work, clickAt: click, windowAt: click.addingTimeInterval(0.4)),
          "nor one whose profile can't be told")
    check(!DockIconRule.broughtByClick(windowProfile: .profile(home), current: work, clickAt: nil, windowAt: click),
          "nor without a click on the icon: the Window menu, App Exposé or a Dock tile is a change of profile")
}

// MARK: - The Dock icon's blank window

do {
    func tab(_ url: String?, loading: Bool = false, id: Int = 1) -> BrowserTab {
        BrowserTab(id: id, windowId: 9, index: id - 1, title: nil, url: url, active: id == 1, pinned: false, audible: false,
                   muted: false, loading: loading, favIconUrl: nil)
    }
    func reported(_ tabs: [BrowserTab]) -> BrowserWindow {
        BrowserWindow(id: 9, focused: true, incognito: false, tabs: tabs)
    }
    let click = Date()
    let soon = click.addingTimeInterval(0.4)
    func verdict(_ tabs: [BrowserTab]?, onList: Bool = false, createdAt: Date? = soon) -> DockIconBlankWindow.Verdict {
        DockIconBlankWindow.verdict(onList: onList, createdAt: createdAt, clickAt: click, newWindows: tabs.map { [reported($0)] })
    }

    check(verdict([tab(nil)]) == .close, "one tab on Safari's Start Page, nothing loaded: Safari's new window is closed")
    check(verdict([tab("")]) == .close && verdict([tab("favorites://")]) == .close && verdict([tab("about:blank")]) == .close,
          "however the copy reports the blank page's address")
    check(verdict([tab("https://example.com/")]) == .keep(.notBlank), "a page loaded in it: minimized as before")
    check(verdict([tab(nil), tab(nil, id: 2)]) == .keep(.severalTabs), "two tabs: minimized")
    check(verdict([tab(nil, loading: true)]) == .keep(.loading), "a page loading: minimized")
    check(verdict(nil) == .keep(.noReport), "no live copy to report it: minimized")
    check(DockIconBlankWindow.verdict(onList: false, createdAt: soon, clickAt: click, newWindows: []) == .keep(.noReport),
          "no report of it from its copy yet: minimized (once the short wait is over)")
    check(verdict([]) == .keep(.noReport), "reported before its tab was: not reported yet")
    check(DockIconBlankWindow.verdict(onList: false, createdAt: soon, clickAt: click, newWindows: [reported([tab(nil)]), reported([tab(nil)])]) == .keep(.unclear),
          "two new windows in its copy: which one it is can't be told, so minimized")
    check(verdict([tab(nil)], onList: true) == .keep(.onList), "a window on the list is never closed, blank or not")
    check(verdict([tab(nil)], createdAt: nil) == .keep(.notNew),
          "a window that wasn't created on the click (macOS brought back a minimized one) is never closed")
    check(verdict([tab(nil)], createdAt: click.addingTimeInterval(DockIconBlankWindow.appearedWithin + 0.5)) == .keep(.notNew),
          "nor one that appeared long after the click")
    check(verdict([tab(nil)], createdAt: click.addingTimeInterval(-0.2)) == .close, "one that appeared just before a click reported late counts")
    check(verdict([tab(nil)], createdAt: click.addingTimeInterval(-2)) == .keep(.notNew), "one from well before the click doesn't")
    check(DockIconBlankWindow.isUntouched(reported([tab(nil)])) && !DockIconBlankWindow.isUntouched(reported([tab("https://example.com/")])),
          "untouched: one blank tab")

    // While Side Tabs decides, sweeps leave that window alone.
    let windows = [ProfileWindow(number: 1, profile: .profile(work)), ProfileWindow(number: 2, profile: .profile(home)), ProfileWindow(number: 3, profile: .profile(school))]
    let spared = MinimizeRules.plan(current: work, left: nil, front: 1, windows: windows, list: MinimizedList(), spare: [3])
    check(spared.minimize == [2], "a sweep spares the window the Dock icon brought out while its fate is decided")
}

if failures > 0 {
    print("\(failures) minimize check(s) failed")
    exit(1)
}
print("minimize checks passed")
