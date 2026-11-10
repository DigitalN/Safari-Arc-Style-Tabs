import Foundation

// Checks for when Settings recommends the Mac's "Minimize windows into application icon" option
// (DockMinimizeOption.swift, #42). Reading the option needs the Dock's preferences, so these cover the
// rule only; they never read or change this Mac's settings.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

func recommends(setting: Bool, option: Bool) -> Bool {
    DockMinimizeOption.recommends(minimizesOtherProfiles: setting, minimizesIntoApplicationIcon: option)
}

// MARK: - When the line shows

check(recommends(setting: true, option: false),
      "with the setting on and the Mac's option off, every minimized window would get a Dock tile: recommend it")
check(!recommends(setting: true, option: true),
      "once the option is on, the line goes away")
check(!recommends(setting: false, option: false),
      "with the setting off, Side Tabs minimizes nothing, so there's nothing to recommend")
check(!recommends(setting: false, option: true),
      "setting off and option on: nothing to say")

// MARK: - Where the button goes

check(DockMinimizeOption.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
      "Open Desktop & Dock opens Desktop & Dock in System Settings")

if failures > 0 {
    print("\(failures) dock recommendation check(s) failed")
    exit(1)
}
print("dock recommendation checks passed")
