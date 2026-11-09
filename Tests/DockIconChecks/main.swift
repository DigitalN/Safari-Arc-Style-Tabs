import CoreGraphics
import Foundation

// Checks for noticing a click on Safari's Dock icon (DockIconRules in SafariDockIconWatcher.swift, #42):
// finding Safari's item in the Dock's Accessibility tree, and whether a press was a plain click on it.
// Run against trees of the Dock kept as data in trees/. No Dock or Safari involved.
//
//   constructed-*.json    Made up, in the format of Tests/TabBarFinderChecks/trees, with a `url` (AXURL)
//                         on each item. Not the Dock's output: nobody has recorded the Dock's tree yet.
//                         The main display is 1512 x 982 points; frames are Accessibility's, with the
//                         origin at the main display's top left.
//
// When the live test finds the Dock answering differently (another layout, a hidden Dock's tiles where
// they'd be when shown, a magnified icon's frame), record that tree here and check against it.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

/// Which elements the search read the children of, as `role#subrole`. Reading costs a round trip to
/// the Dock, so the search should not read what it has no use for.
nonisolated(unsafe) var reads: [String] = []

struct RecordedNode: Decodable, DockNode {
    var role: String?
    var subrole: String?
    var title: String?
    var url: URL?
    var frame: CGRect?
    var kids: [RecordedNode]

    enum CodingKeys: String, CodingKey {
        case role, subrole, title, url, frame
        case kids = "children"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        role = try values.decodeIfPresent(String.self, forKey: .role)
        subrole = try values.decodeIfPresent(String.self, forKey: .subrole)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        url = try values.decodeIfPresent(String.self, forKey: .url).flatMap { URL(string: $0) }
        if let numbers = try values.decodeIfPresent([CGFloat].self, forKey: .frame), numbers.count == 4 {
            frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
        kids = try values.decodeIfPresent([RecordedNode].self, forKey: .kids) ?? []
    }

    func children() -> [RecordedNode] {
        reads.append("\(role ?? "?")#\(subrole ?? "")")
        return kids
    }

    /// Every dock item in the tree, read without the search (and without counting reads).
    var allItems: [RecordedNode] {
        (role == DockIconRules.itemRole ? [self] : []) + kids.flatMap(\.allItems)
    }
}

let treesFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "trees")

func tree(_ name: String) -> RecordedNode {
    do {
        return try JSONDecoder().decode(RecordedNode.self, from: Data(contentsOf: treesFolder.appending(path: "\(name).json")))
    } catch {
        print("FAIL: can't read tree \(name): \(error)")
        exit(1)
    }
}

// Where Safari is on this made-up Mac, as DockItemReader.safariPaths finds it on macOS 26: in the
// system's cryptex. The bundle identifiers stand in for reading each bundle's Info.plist.
let cryptexSafari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
let knownPaths: Set<String> = [cryptexSafari]
let bundleIdentifiers: [String: String] = [
    cryptexSafari: "com.apple.Safari",
    "/Applications/Safari.app": "com.apple.Safari",
    "/Applications/Safari Technology Preview.app": "com.apple.SafariTechnologyPreview",
    "/Users/tester/Applications/Safari.app": "com.apple.Safari.WebApp.5A1F2B3C-0000-4000-8000-000000000001",
    "/System/Library/CoreServices/Finder.app": "com.apple.finder",
    "/System/Applications/Mail.app": "com.apple.mail",
    "/System/Applications/Notes.app": "com.apple.Notes",
    "/System/Applications/Calendar.app": "com.apple.iCal",
]
func onDisk(_ url: URL) -> String? {
    DockIconRules.bundlePath(url).flatMap { bundleIdentifiers[$0] }
}
func isSafari(_ url: URL) -> Bool {
    DockIconRules.isSafariBundle(url, knownPaths: knownPaths, bundleIdentifier: onDisk)
}

func safariItems(_ name: String, isSafari: (URL) -> Bool = isSafari) -> [RecordedNode] {
    reads = []
    return DockIconRules.safariItems(in: tree(name), isSafari: isSafari)
}

func center(_ frame: CGRect?) -> CGPoint {
    CGPoint(x: frame?.midX ?? -10_000, y: frame?.midY ?? -10_000)
}

/// What the Dock would say about Safari's item, from a tree: nil when it has none (no answer).
func dockSample(_ name: String, dockSays: Bool? = nil) -> DockSample? {
    let items = DockIconRules.safariItems(in: tree(name), isSafari: isSafari)
    guard !items.isEmpty else { return nil }
    return DockSample(frames: items.compactMap(\.frame), menuOpen: items.contains { DockIconRules.showsMenu($0) },
                      dockSaysOnItem: dockSays)
}

func press(_ down: CGPoint, to up: CGPoint? = nil, held: TimeInterval = 0.12, farthest: CGFloat? = nil,
           command: Bool = false, control: Bool = false) -> DockPress {
    let up = up ?? CGPoint(x: down.x + 1, y: down.y)
    let moved = hypot(up.x - down.x, up.y - down.y)
    return DockPress(downPoint: down, downTime: 1000, upPoint: up, upTime: 1000 + held, upSeenAt: 5000 + held,
                     farthest: farthest ?? moved, withCommand: command, withControl: control)
}

/// What the watcher makes of a press, the way DockItemReader goes about it: the Dock is asked about
/// the mouse-up only when the mouse-down was on the icon and the press itself could be a click.
func refusal(_ press: DockPress, down downSample: DockSample?, up upSample: DockSample?,
             menuDelay: TimeInterval = DockIconRules.defaultMenuDelay, reportedAfter: TimeInterval = 0.01) -> DockClickRefusal? {
    let down = DockIconRules.hit(press.downPoint, sample: downSample)
    var up: DockHit?
    if down == .onIcon, DockIconRules.pressRefusal(press, menuDelay: menuDelay) == nil {
        up = DockIconRules.hit(press.upPoint, sample: upSample)
    }
    return DockIconRules.refusal(press, down: down, up: up, menuDelay: menuDelay, now: press.upSeenAt + reportedAfter)
}

/// The same Dock at the mouse-down and the mouse-up.
func refusal(_ press: DockPress, in name: String, menuDelay: TimeInterval = DockIconRules.defaultMenuDelay,
             reportedAfter: TimeInterval = 0.01) -> DockClickRefusal? {
    let sample = dockSample(name)
    return refusal(press, down: sample, up: sample, menuDelay: menuDelay, reportedAfter: reportedAfter)
}

func describe(_ refusal: DockClickRefusal?) -> String {
    refusal?.rawValue ?? "counted as a click"
}

// MARK: - Finding Safari's item

do {
    let found = safariItems("constructed-dock-bottom")
    check(found.count == 1, "one Safari item at the bottom: \(found.count)")
    check(found.first?.frame == CGRect(x: 496, y: 916, width: 56, height: 66), "and it's Safari's own icon: \(String(describing: found.first?.frame))")
    check(found.first?.subrole == DockIconRules.applicationSubrole, "an app's item, not the minimized window's tile with Safari's URL")
    check(!reads.contains { $0.hasPrefix(DockIconRules.itemRole) }, "no item is opened while looking: \(reads)")
}

do {
    // Its URL written as the link in /Applications, its title translated, and Notes titled "Safari".
    let found = safariItems("constructed-dock-left-localized")
    check(found.count == 1, "one Safari item on the left: \(found.count)")
    check(found.first?.frame == CGRect(x: 0, y: 412, width: 66, height: 56), "Safari's, whatever its title says: \(String(describing: found.first?.title))")
    check(found.first?.title != "Safari", "the item titled Safari (Notes) isn't taken")
    check(safariItems("constructed-dock-left-localized") { DockIconRules.isSafariBundle($0, knownPaths: knownPaths) { _ in nil } }.isEmpty,
          "the link's path isn't where Safari is known to be: it's found by its bundle identifier")
    check(safariItems("constructed-dock-left-localized") { DockIconRules.isSafariBundle($0, knownPaths: ["/Applications/Safari.app"]) { _ in nil } }.count == 1,
          "and by its path, once that is known")
}

do {
    check(safariItems("constructed-dock-right-second-display").first?.frame == CGRect(x: 3366, y: 212, width: 66, height: 56),
          "on the right of a second display")
    check(safariItems("constructed-dock-bottom-display-above").first?.frame == CGRect(x: 756, y: -66, width: 56, height: 66),
          "at the bottom of a display above the main one")
    check(safariItems("constructed-dock-magnified").first?.frame?.width == 128, "magnified")
    check(safariItems("constructed-dock-hidden").count == 1, "hidden")
    check(safariItems("constructed-dock-menu-open").count == 1, "with its menu showing")
    check(safariItems("constructed-dock-nested").count == 1, "below a wrapper, three levels down")
    check(DockIconRules.searchDepth == 3, "the search goes three levels down")
    check(safariItems("constructed-dock-too-deep").isEmpty, "but no further")
    check(safariItems("constructed-dock-no-safari").isEmpty,
          "no decoy is taken: Safari Technology Preview, a web app called Safari, a minimized Safari window, a link or app titled Safari")
}

do {
    let dock = tree("constructed-dock-menu-open")
    let item = DockIconRules.safariItems(in: dock, isSafari: isSafari).first
    check(item.map(DockIconRules.showsMenu) == true, "Safari's item shows its menu")
    check(DockIconRules.safariItems(in: tree("constructed-dock-bottom"), isSafari: isSafari).first.map(DockIconRules.showsMenu) == false,
          "and an item without a menu doesn't")
}

// MARK: - Which URL is Safari's

do {
    func url(_ text: String) -> URL { URL(string: text)! }
    check(isSafari(url("file://\(cryptexSafari)/")), "Safari's path with a trailing slash")
    check(isSafari(url("file://\(cryptexSafari)")), "and without one")
    check(isSafari(url("file:///Applications/./Safari.app/")), "a path with a dot in it")
    check(isSafari(url("file:///Applications/Safari.app/")), "the link in /Applications, by its bundle identifier")
    check(!isSafari(url("file:///Applications/Safari%20Technology%20Preview.app/")), "not Safari Technology Preview")
    check(!isSafari(url("file:///Users/tester/Applications/Safari.app/")), "not a web app called Safari, whose identifier starts like Safari's")
    check(!isSafari(url("https://www.apple.com/safari/")), "not a link")
    check(!isSafari(url("file:///Applications/Unknown.app/")), "not a bundle without an identifier")
    check(DockIconRules.bundlePath(url("file:///Applications/Safari%20Technology%20Preview.app/")) == "/Applications/Safari Technology Preview.app",
          "paths are compared decoded")
    check(DockIconRules.bundlePath(url("https://example.com/")) == nil, "only files have a path")

    let safari = url("file://\(cryptexSafari)/")
    check(DockIconRules.isSafariItem(role: "AXDockItem", subrole: "AXApplicationDockItem", url: safari, isSafari: isSafari), "Safari's item")
    check(!DockIconRules.isSafariItem(role: "AXDockItem", subrole: "AXMinimizedWindowDockItem", url: safari, isSafari: isSafari),
          "not a minimized window's tile, even with Safari's URL")
    check(!DockIconRules.isSafariItem(role: "AXDockItem", subrole: "AXFolderDockItem", url: safari, isSafari: isSafari), "nor a folder")
    check(!DockIconRules.isSafariItem(role: "AXDockItem", subrole: nil, url: safari, isSafari: isSafari), "nor an item without a subrole")
    check(!DockIconRules.isSafariItem(role: "AXButton", subrole: "AXApplicationDockItem", url: safari, isSafari: isSafari), "nor another role")
    check(!DockIconRules.isSafariItem(role: "AXDockItem", subrole: "AXApplicationDockItem", url: nil, isSafari: { _ in true }),
          "nor an item without a URL")
}

// MARK: - Where a press is

do {
    let frame = CGRect(x: 496, y: 916, width: 56, height: 66)
    let sample = DockSample(frames: [frame], menuOpen: false, dockSaysOnItem: nil)
    check(DockIconRules.hit(CGPoint(x: 524, y: 949), sample: sample) == .onIcon, "in the frame")
    check(DockIconRules.hit(CGPoint(x: 552, y: 982), sample: sample) == .onIcon, "on its far corner, the bottom edge of the screen")
    check(DockIconRules.hit(CGPoint(x: 496, y: 916), sample: sample) == .onIcon, "on its near corner")
    check(DockIconRules.hit(CGPoint(x: 552.5, y: 949), sample: sample) == .elsewhere, "half a point past its edge")
    check(DockIconRules.hit(CGPoint(x: 524, y: 949), sample: nil) == .noAnswer, "the Dock didn't answer")
    check(DockIconRules.hit(CGPoint(x: 524, y: 949), sample: DockSample(frames: [], menuOpen: false)) == .noAnswer, "no item for Safari")
    check(DockIconRules.hit(CGPoint(x: 524, y: 949), sample: DockSample(frames: [frame], menuOpen: true)) == .menuOpen, "its menu showing")
    check(DockIconRules.hit(CGPoint(x: 524, y: 900), sample: DockSample(frames: [frame], menuOpen: false, dockSaysOnItem: true)) == .onIcon,
          "outside the frame, but the Dock says Safari's item is there (magnified)")
    check(DockIconRules.hit(CGPoint(x: 524, y: 900), sample: DockSample(frames: [frame], menuOpen: false, dockSaysOnItem: false)) == .elsewhere,
          "outside the frame, and the Dock agrees")
    check(DockIconRules.hit(CGPoint(x: 496, y: 916), sample: DockSample(frames: [CGRect(x: 496, y: 916, width: 0, height: 66)], menuOpen: false)) == .elsewhere,
          "a frame with no area contains nothing")
    check(DockIconRules.hit(CGPoint(x: 3399, y: 240), sample: DockSample(frames: [frame, CGRect(x: 3366, y: 212, width: 66, height: 56)], menuOpen: false)) == .onIcon,
          "in either of two frames")

    check(DockIconRules.isNear(CGPoint(x: 524, y: 949), frames: [frame]), "the Dock is asked about a point on the icon")
    check(DockIconRules.isNear(CGPoint(x: 524, y: 820), frames: [frame]), "and near it, where a magnified icon reaches")
    check(!DockIconRules.isNear(CGPoint(x: 524, y: 700), frames: [frame]), "but not far from it")
    check(!DockIconRules.isNear(CGPoint(x: 1200, y: 400), frames: [frame]), "nor about a click in the middle of the screen")
}

do {
    check(DockIconRules.quartzPoint(cocoa: CGPoint(x: 100, y: 0), primaryScreenHeight: 982) == CGPoint(x: 100, y: 982),
          "the bottom of the main display, in Accessibility's coordinates")
    check(DockIconRules.quartzPoint(cocoa: CGPoint(x: 100, y: 1500), primaryScreenHeight: 982) == CGPoint(x: 100, y: -518),
          "a display above the main one is at negative y")
    check(DockIconRules.quartzPoint(cocoa: CGPoint(x: -300, y: -50), primaryScreenHeight: 982) == CGPoint(x: -300, y: 1032),
          "a display to the left and below")
}

// MARK: - The Dock's menu delay

do {
    check(DockIconRules.menuDelay(preference: nil) == 0.5, "the Dock's default menu delay")
    check(DockIconRules.menuDelay(preference: 0) == 0.5 && DockIconRules.menuDelay(preference: -1) == 0.5,
          "a delay that isn't above zero is the default, as the Dock takes it")
    check(DockIconRules.menuDelay(preference: 0.3) == 0.3, "a shorter delay")
    check(abs(DockIconRules.longestClick(menuDelay: 0.5) - 0.4) < 1e-9, "the longest click is 0.4 s with the default delay")
    check(DockIconRules.longestClick(menuDelay: 0.5) < 0.5, "always under the delay")
    check(DockIconRules.longestClick(menuDelay: 10) == 1, "and never more than a second")
}

// MARK: - Plain clicks count, wherever the Dock is

for name in ["constructed-dock-bottom", "constructed-dock-left-localized", "constructed-dock-right-second-display",
             "constructed-dock-bottom-display-above", "constructed-dock-magnified", "constructed-dock-nested"] {
    let dock = tree(name)
    let safari = DockIconRules.safariItems(in: dock, isSafari: isSafari)
    let safariFrame = safari.first?.frame
    check(refusal(press(center(safariFrame)), in: name) == nil,
          "\(name): a click on Safari's icon counts: \(describe(refusal(press(center(safariFrame)), in: name)))")
    for other in dock.allItems where other.frame != safariFrame {
        if let frame = other.frame, frame.width > 0 {
            let result = refusal(press(center(frame)), in: name)
            check(result == .startedElsewhere, "\(name): a click on \(other.subrole ?? "?") \(other.title ?? "") doesn't: \(describe(result))")
        }
    }
}

do {
    let onSecond = center(CGRect(x: 3366, y: 212, width: 66, height: 56))
    check(refusal(press(onSecond), in: "constructed-dock-right-second-display") == nil, "on the second display")
    check(refusal(press(CGPoint(x: 1500, y: onSecond.y)), in: "constructed-dock-right-second-display") == .startedElsewhere,
          "not the right edge of the main display, at the same height")
}

// MARK: - Only a plain click

do {
    let icon = center(CGRect(x: 496, y: 916, width: 56, height: 66))
    let bottom = "constructed-dock-bottom"
    check(refusal(press(icon, held: 0.02), in: bottom) == nil, "a quick tap")
    check(refusal(press(icon, held: 0.39), in: bottom) == nil, "a slow click, under 0.4 s")
    check(refusal(press(icon, held: 0.41), in: bottom) == .heldTooLong, "just over 0.4 s is too long: the Dock opens the menu at 0.5")
    check(refusal(press(icon, held: 0.6), in: bottom) == .heldTooLong, "a press held until the menu opened")
    check(refusal(press(icon, held: -0.01), in: bottom) == .heldTooLong, "a mouse-up from before the mouse-down")
    check(refusal(press(icon, held: 0.6), in: bottom, menuDelay: 1.0) == nil, "with a longer menu delay, a longer click counts")
    check(refusal(press(icon, held: 0.81), in: bottom, menuDelay: 1.0) == .heldTooLong, "up to 0.8 s of it")
    check(refusal(press(icon, held: 0.25), in: bottom, menuDelay: 0.3) == .heldTooLong, "with a shorter one, less")

    check(refusal(press(icon, to: CGPoint(x: icon.x + 6, y: icon.y)), in: bottom) == nil, "a click that wobbled 6 points")
    check(refusal(press(icon, to: CGPoint(x: icon.x + 6.5, y: icon.y)), in: bottom) == .moved, "a press that moved further is a drag")
    check(refusal(press(icon, to: CGPoint(x: icon.x + 1, y: icon.y), farthest: 20), in: bottom) == .moved,
          "even one that came back to where it started")

    check(refusal(press(icon, command: true), in: bottom) == .withModifier, "a Command-click shows Safari in the Finder")
    check(refusal(press(icon, control: true), in: bottom) == .withModifier, "a Control-click opens the menu")

    // Off the edge of the icon by the end: next to Safari is Mail.
    let edge = CGPoint(x: 550, y: 949)
    check(refusal(press(edge, to: CGPoint(x: 554, y: 949)), in: bottom) == .endedElsewhere, "a press that ends off the icon")
    check(refusal(press(CGPoint(x: 554, y: 949), to: edge), in: bottom) == .startedElsewhere, "or starts off it")
    check(refusal(press(CGPoint(x: 468, y: 949), to: icon), in: bottom) == .startedElsewhere,
          "a press from Finder to Safari: it started elsewhere")
}

do {
    let icon = center(CGRect(x: 496, y: 916, width: 56, height: 66))
    let menu = "constructed-dock-menu-open"
    check(refusal(press(icon), in: menu) == .menuOpen, "a click on the icon while its menu shows (it closes the menu)")
    let showAllWindows = center(CGRect(x: 496, y: 832, width: 220, height: 24))
    check(refusal(press(showAllWindows), in: menu) == .menuOpen, "a choice in the menu")
    check(refusal(press(icon, held: 0.3), down: dockSample("constructed-dock-bottom"), up: dockSample(menu)) == .menuOpen,
          "a press during which the menu opened")
}

do {
    let icon = center(CGRect(x: 496, y: 916, width: 56, height: 66))
    let sample = dockSample("constructed-dock-bottom")
    check(refusal(press(icon), down: nil, up: sample) == .noAnswer, "the Dock didn't answer at the mouse-down")
    check(refusal(press(icon), down: sample, up: nil) == .noAnswer, "nor at the mouse-up")
    check(refusal(press(icon), in: "constructed-dock-no-safari") == .noAnswer, "no item for Safari")
    check(refusal(press(icon), in: "constructed-dock-bottom", reportedAfter: 0.45) == nil, "confirmed within half a second of the mouse-up")
    check(refusal(press(icon), in: "constructed-dock-bottom", reportedAfter: 0.6) == .late, "not later")
    check(refusal(press(icon, held: 0.6), in: "constructed-dock-bottom", reportedAfter: 0.6) == .heldTooLong,
          "the press's own fault comes first")
}

// MARK: - Hiding and magnification

do {
    // Hidden: a click near the bottom of the screen, where Safari's icon is when the Dock shows.
    let hidden = "constructed-dock-hidden"
    check(refusal(press(CGPoint(x: 524, y: 950)), in: hidden) == .startedElsewhere, "a click where the hidden Dock's icon would be")
    check(refusal(press(CGPoint(x: 524, y: 981)), in: hidden) == .startedElsewhere, "and at the bottom edge")

    let magnified = "constructed-dock-magnified"
    check(refusal(press(CGPoint(x: 534, y: 850)), in: magnified) == nil, "high on the magnified icon")
    check(refusal(press(CGPoint(x: 534, y: 850)), in: "constructed-dock-bottom") == .startedElsewhere,
          "which the frame without magnification doesn't reach")
    let unmagnifiedFrame = dockSample("constructed-dock-bottom", dockSays: true)
    check(refusal(press(CGPoint(x: 534, y: 850)), down: unmagnifiedFrame, up: unmagnifiedFrame) == nil,
          "but the Dock's own answer does, if Accessibility gives the frame without magnification")
    check(refusal(press(CGPoint(x: 520, y: 940)), down: dockSample("constructed-dock-bottom"), up: dockSample(magnified)) == nil,
          "the icon grew between the mouse-down and the mouse-up")
}

check(Set([DockClickRefusal.startedElsewhere, .endedElsewhere, .menuOpen, .noAnswer, .heldTooLong, .moved, .withModifier, .late].map(\.rawValue)).count == 8,
      "every refusal says something different in the log")

if failures == 0 {
    print("Dock icon checks passed")
} else {
    print("\(failures) Dock icon check(s) failed")
    exit(1)
}
