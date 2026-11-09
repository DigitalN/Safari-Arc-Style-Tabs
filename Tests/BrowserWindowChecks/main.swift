import Foundation

// Checks for which of Safari's windows the sidebar docks to (BrowserWindowRule.swift), run against
// trees of Safari's windows kept as data in ../TabBarFinderChecks/trees. No Safari involved.
//
//   settings-*.json   #28 recorded these in Safari 27.2: Settings → Profiles (General and Extensions
//                     tabs) and Settings → Extensions. Identifier `_NS:111`, a standard window, a
//                     disabled zoom button and no full-screen button (#32).
//   window-*.json     Browser windows from the same Safari: a test page, a private window, a new
//                     window in a second profile, and a real window recorded while minimized, which
//                     reports itself as a dialog (`AXDialog`).
//
// Only the window's own attributes and its buttons matter here. A window's buttons are among its
// children in the files, with their subroles; Safari also hands them out as the window's
// `AXFullScreenButton` and `AXZoomButton`, which is how the app reads them. `AXMinimized` and
// `AXFullScreen` aren't in the files, so the checks set them where they matter.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

struct RecordedWindow: Decodable {
    var role: String?
    var subrole: String?
    var identifier: String?
    var enabled: Bool?
    var children: [RecordedWindow]?
}

let treesFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "TabBarFinderChecks/trees")

func recorded(_ name: String) -> RecordedWindow {
    do {
        return try JSONDecoder().decode(RecordedWindow.self, from: Data(contentsOf: treesFolder.appending(path: "\(name).json")))
    } catch {
        print("FAIL: can't read tree \(name): \(error)")
        exit(1)
    }
}

func button(_ subrole: String, of window: RecordedWindow) -> WindowButtonState {
    guard let button = window.children?.first(where: { $0.subrole == subrole }) else { return .missing }
    switch button.enabled {
    case true?: return .enabled
    case false?: return .disabled
    case nil: return .unknown
    }
}

/// Everything about the window, buttons included.
func allTraits(_ window: RecordedWindow) -> WindowTraits {
    WindowTraits(
        role: window.role,
        subrole: window.subrole,
        identifier: window.identifier,
        isMinimized: false,
        isFullScreen: false,
        fullScreenButton: button("AXFullScreenButton", of: window),
        zoomButton: button("AXZoomButton", of: window)
    )
}

/// What the app reads (WindowTraits.read): the buttons only when the rule needs them, and the zoom
/// button only when there's no full-screen button.
func asRead(_ window: WindowTraits) -> WindowTraits {
    var read = window
    read.fullScreenButton = nil
    read.zoomButton = nil
    guard BrowserWindowRule.needsButtons(read) else { return read }
    read.fullScreenButton = window.fullScreenButton
    if read.fullScreenButton == .missing {
        read.zoomButton = window.zoomButton
    }
    return read
}

func traits(_ name: String) -> WindowTraits { allTraits(recorded(name)) }

/// The rule as it was before #32 (SafariWindowReader.isBrowserWindow): a standard window that isn't
/// minimized, and is full screen or has a full-screen button that isn't disabled, or has none.
func previousRule(_ window: WindowTraits) -> Bool {
    guard window.role == "AXWindow", window.subrole == "AXStandardWindow", window.isMinimized != true else { return false }
    if window.isFullScreen == true { return true }
    return window.fullScreenButton != .disabled
}

let settingsPanes = ["settings-profiles-general-tab", "settings-profiles-extensions-tab", "settings-extensions-pane"]
let browserWindows = ["window-personal-test-page", "window-private", "window-work-new-window-start-page"]

// MARK: - Settings (recorded): never a browser window

for name in settingsPanes {
    let settings = traits(name)
    check(settings.identifier == "_NS:111", "\(name): Settings has the identifier _NS:111: \(settings.summary)")
    check(settings.subrole == "AXStandardWindow" && settings.fullScreenButton == .missing && settings.zoomButton == .disabled,
          "\(name): and looks like a standard window with a disabled zoom button and no full-screen button: \(settings.summary)")
    check(previousRule(settings), "\(name): the rule before #32 took it for a browser window (the bug this fixes)")
    check(!BrowserWindowRule.isBrowserWindow(settings), "\(name): isn't a browser window: \(settings.summary)")
    check(!BrowserWindowRule.canDock(settings), "\(name): and the sidebar doesn't dock to it")
    check(!BrowserWindowRule.needsButtons(settings), "\(name): its identifier decides, without reading its buttons")
    check(!BrowserWindowRule.canDock(asRead(settings)), "\(name): read the way the app reads it, it isn't docked to either")
}

// MARK: - Browser windows (recorded), private ones included

for name in browserWindows {
    let window = traits(name)
    check(window.identifier.map(BrowserWindowRule.isBrowserIdentifier) == true, "\(name): has a SafariWindow identifier")
    check(BrowserWindowRule.isBrowserWindow(window), "\(name): is a browser window: \(window.summary)")
    check(BrowserWindowRule.canDock(window), "\(name): and can be docked to")
    check(!BrowserWindowRule.needsButtons(window), "\(name): in one round trip, without its buttons")
    check(BrowserWindowRule.canDock(asRead(window)), "\(name): read the way the app reads it, it's docked to")
}

// MARK: - A minimized browser window (recorded)

do {
    var minimized = traits("window-personal-minimized-real")
    minimized.isMinimized = true
    check(minimized.subrole == "AXDialog", "a minimized browser window reports itself as a dialog: \(minimized.summary)")
    check(BrowserWindowRule.isBrowserWindow(minimized), "it's still a browser window, by its identifier (its profile still counts)")
    check(!BrowserWindowRule.canDock(minimized), "but the sidebar doesn't dock to it")
    minimized.isMinimized = false
    check(BrowserWindowRule.canDock(minimized), "once it's back, the sidebar docks to it, whatever its subrole says on the way")
    minimized.isMinimized = true
    minimized.identifier = nil
    check(!BrowserWindowRule.isBrowserWindow(minimized), "without an identifier, a dialog isn't a browser window")
}

// MARK: - Windows without an identifier: the buttons decide, as before, plus the zoom button

for name in settingsPanes {
    for missing in [nil, ""] as [String?] {
        var settings = traits(name)
        settings.identifier = missing
        check(BrowserWindowRule.needsButtons(settings), "\(name) without an identifier (\(missing == nil ? "none" : "empty")): the buttons are read")
        check(!BrowserWindowRule.isBrowserWindow(settings), "\(name) without an identifier: its disabled zoom button and no full-screen button rule it out")
        check(!BrowserWindowRule.canDock(asRead(settings)), "\(name) without an identifier: read the way the app reads it, it isn't docked to")
    }
}

for name in browserWindows {
    var window = traits(name)
    window.identifier = nil
    check(BrowserWindowRule.needsButtons(window), "\(name) without an identifier: the buttons are read")
    check(BrowserWindowRule.canDock(window), "\(name) without an identifier: its enabled full-screen button makes it a browser window")
    check(BrowserWindowRule.canDock(asRead(window)), "\(name) without an identifier: also read the way the app reads it")

    // Safari leaves the full-screen button out of a browser window for a few seconds now and then.
    window.fullScreenButton = .missing
    check(window.zoomButton == .missing, "\(name): browser windows have no zoom button")
    check(BrowserWindowRule.canDock(window), "\(name) without an identifier or a full-screen button: still a browser window")
    window.zoomButton = .enabled
    check(BrowserWindowRule.canDock(window), "\(name) without an identifier or a full-screen button, with an enabled zoom button: still a browser window")
    window.zoomButton = .disabled
    check(!BrowserWindowRule.canDock(window), "\(name) without an identifier or a full-screen button, with a disabled zoom button: looks like Settings, not docked to")

    window.fullScreenButton = .disabled
    window.zoomButton = .missing
    check(!BrowserWindowRule.canDock(window), "\(name) without an identifier, with a disabled full-screen button (Settings before Safari 27): not docked to")
    window.fullScreenButton = .unknown
    check(BrowserWindowRule.canDock(window), "\(name) without an identifier, with a full-screen button Safari didn't say about: a browser window, as before")
    window.fullScreenButton = .disabled
    window.isFullScreen = true
    check(!BrowserWindowRule.needsButtons(window), "\(name) without an identifier, full screen: the buttons aren't read")
    check(BrowserWindowRule.canDock(window), "\(name) without an identifier, full screen: a browser window (Settings can't go full screen)")
    window.isFullScreen = false
    window.fullScreenButton = .enabled
    window.isMinimized = true
    check(!BrowserWindowRule.canDock(window), "\(name) without an identifier, minimized: not docked to")
    window.isMinimized = false
    window.subrole = "AXDialog"
    check(!BrowserWindowRule.canDock(window), "\(name) without an identifier, a dialog: not docked to")
}

// MARK: - With an identifier, the buttons don't matter

for name in browserWindows {
    var window = traits(name)
    window.fullScreenButton = .missing
    check(BrowserWindowRule.canDock(window), "\(name) without its full-screen button: still docked to, by its identifier")
    window.fullScreenButton = .disabled
    window.zoomButton = .disabled
    check(BrowserWindowRule.canDock(window), "\(name) with disabled buttons: still docked to, by its identifier")
    window.subrole = "AXStandardWindow"
    window.isFullScreen = true
    check(BrowserWindowRule.canDock(window), "\(name) full screen: docked to")
}

// Made up: windows nobody has recorded, such as a detached Web Inspector, with a full-screen button
// that works. Any identifier but a browser window's rules a window out.
do {
    var other = traits("window-personal-test-page")
    for identifier in ["_NS:5", "WebInspectorWindow", "SafariWindowLike", "safariwindow?IsSecure=false", "Safari"] {
        other.identifier = identifier
        check(!BrowserWindowRule.isBrowserWindow(other), "a window with the identifier \(identifier) isn't a browser window")
    }
    other.identifier = "SafariWindow"
    check(BrowserWindowRule.isBrowserWindow(other), "SafariWindow alone is a browser window's identifier")
    other.identifier = "SafariWindow?IsSecure=true&UUID=00000000-0000-0000-0000-000000000000"
    other.role = "AXSheet"
    check(!BrowserWindowRule.isBrowserWindow(other), "a sheet isn't a window")
    other.role = nil
    check(!BrowserWindowRule.isBrowserWindow(other), "nor is something whose role Safari didn't give")
    check(!BrowserWindowRule.isBrowserWindow(WindowTraits()), "nor a window nothing could be read from")
}

// MARK: - The log never carries more of an identifier than what comes before its "?"

do {
    let window = traits("window-private")
    check(window.summary.contains("identifier=SafariWindow "), "a browser window's identifier is logged as SafariWindow: \(window.summary)")
    check(!window.summary.contains("UUID") && !window.summary.contains("?"), "without its UUID: \(window.summary)")
    check(traits("settings-extensions-pane").summary.contains("identifier=_NS:111 "), "Settings' identifier is logged as it is")
    var made = window
    made.identifier = nil
    check(made.summary.contains("identifier=none"), "a missing identifier says so")
    made.identifier = String(repeating: "x", count: 200)
    check(made.summary.count < 300, "a long identifier is cut short")
}

// MARK: - Choosing the window to dock to

/// A window for the chooser checks: a recorded tree, by name, so the rule runs on what Safari said.
struct Window: Equatable {
    var name: String
    var traits: WindowTraits
    init(_ name: String, minimized: Bool = false) {
        self.name = name
        traits = allTraits(recorded(name))
        traits.isMinimized = minimized
    }
}

/// Runs the chooser, keeping count of what it read.
func choose(
    focused: Window?,
    main: Window? = nil,
    current: Window? = nil,
    windows: [Window] = [],
    gaveUpAfter: Int? = nil
) -> (chosen: Window?, looked: [String], readMain: Bool, readWindows: Bool) {
    var looked: [String] = []
    var readMain = false
    var readWindows = false
    let chosen = BrowserWindowRule.choose(
        focused: focused,
        main: { readMain = true; return main },
        current: current,
        windows: { readWindows = true; return windows },
        canDock: { window in
            looked.append(window.name)
            return BrowserWindowRule.canDock(asRead(window.traits))
        },
        gaveUp: { gaveUpAfter.map { looked.count >= $0 } ?? false }
    )
    return (chosen, looked, readMain, readWindows)
}

let settings = Window("settings-profiles-general-tab")
let personal = Window("window-personal-test-page")
let privateWindow = Window("window-private")
let work = Window("window-work-new-window-start-page")
let minimized = Window("window-personal-minimized-real", minimized: true)

do {
    // #32: Settings in front of the window the sidebar is docked to. Settings is also Safari's main
    // window then.
    let result = choose(focused: settings, main: settings, current: personal, windows: [settings, personal])
    check(result.chosen == personal, "with Settings in front, the sidebar stays with the browser window it was docked to, not \(result.chosen?.name ?? "nil")")
    check(!result.readWindows, "without reading Safari's window list")

    // Every Settings pane the same.
    for name in settingsPanes {
        let pane = Window(name)
        check(choose(focused: pane, main: pane, current: work, windows: [pane, work]).chosen == work, "with \(name) in front, the sidebar stays with its window")
    }

    // Settings in front before the sidebar has docked anywhere (Safari just launched with Settings
    // open, or Side Tabs just started): the frontmost browser window.
    let fresh = choose(focused: settings, main: settings, current: nil, windows: [settings, privateWindow, personal])
    check(fresh.chosen == privateWindow, "with Settings in front and nothing docked yet, the frontmost browser window: \(fresh.chosen?.name ?? "nil")")

    // The docked window was minimized while Settings is in front.
    let afterMinimizing = choose(focused: settings, main: settings, current: minimized, windows: [settings, minimized, work])
    check(afterMinimizing.chosen == work, "a minimized window is passed over for the next browser window: \(afterMinimizing.chosen?.name ?? "nil")")

    // Only Settings left.
    let onlySettings = choose(focused: settings, main: settings, current: nil, windows: [settings])
    check(onlySettings.chosen == nil, "with only Settings open, there's nothing to dock to")
    let onlyMinimized = choose(focused: settings, main: settings, current: minimized, windows: [settings, minimized])
    check(onlyMinimized.chosen == nil, "nor with only Settings and a minimized window")

    // A browser window in front: it's the one, with nothing else read.
    let switched = choose(focused: work, main: work, current: personal, windows: [work, personal])
    check(switched.chosen == work, "a browser window that comes to the front is docked to")
    check(!switched.readMain && !switched.readWindows && switched.looked == [work.name], "after one look: \(switched.looked)")

    // Something that isn't a window has focus, and the main window is a browser window.
    let mainWindow = choose(focused: nil, main: privateWindow, current: personal)
    check(mainWindow.chosen == privateWindow, "with no focused window, Safari's main window, if it's a browser window")

    // Settings has focus but another browser window is main.
    let behind = choose(focused: settings, main: work, current: personal)
    check(behind.chosen == work, "Safari's main window wins over the one docked to now")

    // Safari stops answering.
    let silent = choose(focused: settings, main: personal, current: personal, windows: [personal], gaveUpAfter: 1)
    check(silent.chosen == nil, "when Safari stops answering, no window is chosen (the tracker keeps what it had)")
    check(!silent.readMain && !silent.readWindows, "and nothing more is read")
    let silentLater = choose(focused: settings, main: work, current: personal, windows: [work], gaveUpAfter: 2)
    check(silentLater.chosen == nil, "even if the window it last looked at could be docked to: \(silentLater.chosen?.name ?? "nil")")
}

if failures > 0 {
    print("\(failures) browser window check(s) failed")
    exit(1)
}
print("browser window checks passed")
