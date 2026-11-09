import Foundation

// Checks for what the sidebar shows while a profile switch's window comes back from the Dock (#44): the
// switch's target matched to a window of the profile's extension copy, by last focus and by title, the
// placeholder when it can't be told, what Safari's later report does to the guess, and that a switch to a
// window that's already open doesn't fade. No Safari involved: the rules in SwitchPreviewRules.swift. How the
// store shows the guess and ends it is in Tests/StoreChecks.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

let work = ProfileKey(rawValue: "WORK-UUID")
let home = ProfileKey.defaultProfile

func tab(_ id: Int, window: Int, title: String?, active: Bool = false) -> BrowserTab {
    BrowserTab(id: id, windowId: window, index: 0, title: title, url: nil, active: active, pinned: false, audible: false,
               muted: false, loading: false, favIconUrl: nil)
}

func window(_ id: Int, page: String?, incognito: Bool = false, others: [String] = []) -> BrowserWindow {
    var tabs = [tab(id * 10, window: id, title: page, active: true)]
    for (offset, title) in others.enumerated() {
        tabs.append(tab(id * 10 + offset + 1, window: id, title: title))
    }
    return BrowserWindow(id: id, focused: false, incognito: incognito, tabs: tabs)
}

func snapshot(_ instance: String, profile: ProfileKey, focused: Int? = -1, lastFocused: Int? = nil, focusChangedAt: Double = 1,
              _ windows: [BrowserWindow]) -> Snapshot {
    Snapshot(instance: instance, seq: 1, focusedWindowId: focused, lastFocusedWindowId: lastFocused, focusChangedAt: focusChangedAt,
             startedAt: nil, windows: windows, profile: profile.isDefault ? nil : profile.rawValue)
}

// Home's copy has the window in front; Work's copy has three windows, the one used last is 22.
let homeCopy = snapshot("H", profile: home, focused: 1, lastFocused: 1, focusChangedAt: 20, [window(1, page: "News")])
let workCopy = snapshot("W", profile: work, focused: -1, lastFocused: 22, focusChangedAt: 10, [
    window(21, page: "Mail"),
    window(22, page: "Docs — Intro", others: ["Calendar"]),
    window(23, page: "Intro"),
    window(24, page: "Mail", incognito: true),
])
let copies = [homeCopy, workCopy]

// MARK: - The target matched to the copy's window

do {
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work), copies: copies) == .window(instance: "W", windowId: 22),
          "at the click, before the switch has picked its window: the copy's last focused window, the one used last")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work, title: "Work — Mail"), copies: copies) == .window(instance: "W", windowId: 21),
          "once the switch has picked its window: the copy's window whose active tab fits the title, after the profile's name")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work, title: "Work — Docs — Intro"), copies: copies) == .window(instance: "W", windowId: 22),
          "of windows whose page fits, the one with the longest page title: a shorter one fits only by accident")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work, title: "Work — Calendar"), copies: copies) == .placeholder,
          "only the active tab counts, as for the window the sidebar shows")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: home, title: "News"), copies: copies) == .window(instance: "H", windowId: 1),
          "a profile's page title without a profile name (Safari with one profile) fits as it is")

    // Two windows on the same page: the copy's last focused one, if it's one of them.
    let twins = snapshot("W", profile: work, focused: -1, lastFocused: 32, [window(31, page: "Mail"), window(32, page: "Mail")])
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work, title: "Work — Mail"), copies: [twins]) == .window(instance: "W", windowId: 32),
          "two windows on the target's page: the copy's last focused one")
    let twinsElsewhere = snapshot("W", profile: work, focused: -1, lastFocused: 33,
                                  [window(31, page: "Mail"), window(32, page: "Mail"), window(33, page: "News")])
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work, title: "Work — Mail"), copies: [twinsElsewhere]) == .placeholder,
          "and when it was neither, it can't be told")

    // A copy that reported focus on one window most recently.
    let focusedNow = snapshot("W", profile: work, focused: 21, lastFocused: 22, [window(21, page: "Mail"), window(22, page: "Docs")])
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work), copies: [focusedNow]) == .window(instance: "W", windowId: 21),
          "a window the copy still says is focused counts as its last focused")
    let one = snapshot("W", profile: work, focused: -1, lastFocused: nil, [window(21, page: "Mail")])
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work), copies: [one]) == .window(instance: "W", windowId: 21),
          "with no focus known, the copy's only window")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work), copies: [homeCopy, workCopy]) != .window(instance: "H", windowId: 1),
          "never another profile's window")
}

// MARK: - When it can't be told

do {
    let unfocused = snapshot("W", profile: work, focused: -1, lastFocused: nil, [window(21, page: "Mail"), window(22, page: "Docs")])
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work), copies: [unfocused]) == .placeholder,
          "several windows and no focus known: the profile's lists and a placeholder, never a guess between them")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work, isNewWindow: true), copies: copies) == .placeholder,
          "a profile with no window gets a new one, whose tabs aren't known yet")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work, title: "Work — Weather"), copies: copies) == .placeholder,
          "no window of the copy on the target's page: a placeholder, not the last focused window")
    let other = ProfileKey(rawValue: "SCHOOL-UUID")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: other), copies: copies) == .placeholder,
          "a profile with no live copy (Side Tabs is off there): a placeholder")
    let privateOnly = snapshot("H", profile: home, focused: 5, lastFocused: 5, [window(5, page: "News", incognito: true)])
    check(SwitchPreviewRules.guess(SwitchTarget(profile: home), copies: [privateOnly]) == .placeholder,
          "a private window is no profile's, even when the default profile's copy last had it focused")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: home, title: "News, Private Browsing"), copies: [privateOnly]) == .placeholder,
          "nor does its title fit")

    // #41: a window the copy can't see.
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work, title: "Work — Weather", profileWindowCount: 4), copies: copies) == .unseen,
          "Safari has more of the profile's windows than its copy lists, and none on the target's page: the copy can't see it")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: work, title: "Work — Weather", profileWindowCount: 3), copies: copies) == .placeholder,
          "a copy that lists every window of the profile can see the target; it's only behind on a title")
    check(SwitchPreviewRules.guess(SwitchTarget(profile: other, title: "School — Weather", profileWindowCount: 2), copies: copies) == .placeholder,
          "with no live copy there's nothing to be unseen by")
}

// MARK: - Safari's report

do {
    let guess = SwitchGuess.window(instance: "W", windowId: 22)
    check(SwitchPreviewRules.report(guess, shown: .window(instance: "W", windowId: 22)) == .kept,
          "when Safari reports the guessed window, the sidebar keeps what it shows")
    check(SwitchPreviewRules.report(guess, shown: .window(instance: "W", windowId: 21)) == .corrected,
          "when it reports another, the sidebar changes to it")
    check(SwitchPreviewRules.report(.placeholder, shown: .window(instance: "W", windowId: 21)) == .corrected,
          "a placeholder always gives way to the window reported")
    check(SwitchPreviewRules.report(.unseen, shown: .unseen) == .kept, "a window its copy can't see stays the tab bar list")
    check(SwitchPreviewRules.report(guess, shown: .unseen) == .corrected, "and a guessed window that turns out unseen changes to the tab bar list")
}

// MARK: - When it fades

do {
    check(!SwitchPreviewRules.fades(targetIsMinimized: false, minimizesOtherProfiles: false),
          "no fade when the target window is already open: the sidebar follows Safari, as before")
    check(!SwitchPreviewRules.fades(targetIsMinimized: false, minimizesOtherProfiles: true), "whatever the setting")
    check(SwitchPreviewRules.fades(targetIsMinimized: true, minimizesOtherProfiles: false), "a target in the Dock fades, with the setting off too")
    check(SwitchPreviewRules.fades(targetIsMinimized: nil, minimizesOtherProfiles: true),
          "at the click, with the setting on, the target is nearly always in the Dock: the fade starts at once")
    check(!SwitchPreviewRules.fades(targetIsMinimized: nil, minimizesOtherProfiles: false), "with it off, the switch says first")
}

// MARK: - The fade's timing: out, then in, ending as the window lands

do {
    let genie = SwitchPreviewRules.arrivalEstimate(minimizeEffect: "genie")
    check(abs(genie - 0.76) < 0.001 && SwitchPreviewRules.arrivalEstimate(minimizeEffect: nil) == genie,
          "with the Genie effect (the default), a minimized window lands about 0.76 s after the click, as measured")
    check(SwitchPreviewRules.arrivalEstimate(minimizeEffect: "scale") < genie, "sooner with the Scale effect")
    check(SwitchPreviewRules.fadeOut <= 0.15, "the old contents fade out quickly")

    // Fully out before anything comes in, and fully in as the window lands.
    let click = Date()
    let lands = click.addingTimeInterval(genie)
    let outEnds = click.addingTimeInterval(SwitchPreviewRules.fadeOut)
    let fadeIn = SwitchPreviewRules.fadeIn(arrivesAt: lands, now: outEnds)
    check(abs(SwitchPreviewRules.fadeOut + fadeIn - genie) < 0.001, "the fade-in takes the rest, ending as the window lands")
    check(fadeIn > SwitchPreviewRules.fadeOut * 3, "most of the time is the fade-in")
    check(SwitchPreviewRules.fadeIn(arrivesAt: click, now: outEnds) == SwitchPreviewRules.shortestFadeIn,
          "a window that has landed already: a short fade-in all the same")

    // Measured switches tune the estimate.
    let measured = SwitchPreviewRules.arrivalEstimate(after: genie, measured: 0.9)
    check(measured > genie && measured < 0.9, "a slower switch moves the estimate halfway towards it")
    check(SwitchPreviewRules.arrivalEstimate(after: genie, measured: 9) <= 1.5 && SwitchPreviewRules.arrivalEstimate(after: 0.3, measured: 0) >= 0.3,
          "within reason: a switch held up by something else doesn't throw it off")
}

if failures > 0 {
    print("\(failures) switch preview check(s) failed")
    exit(1)
}
print("switch preview checks passed")
