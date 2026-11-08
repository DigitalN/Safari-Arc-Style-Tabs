import ApplicationServices
import Foundation

// Checks for which notifications the sidebar watches on the window it's docked to
// (DockedWindowNotifications.swift). What Safari sends, and what the dock does with the title
// afterwards, need the running app; these cover the part that decides what is asked for.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

let names = DockedWindowNotifications.names

// The docked window's title changes with every tab switch and page title (#22 item 4). Without
// this notification the store's copy of it is only refreshed by moves, resizes and focus changes,
// and is usually old.
check(names.contains(kAXTitleChangedNotification), "title changes on the docked window are asked for")
check(DockedWindowNotifications.isTitleChange(kAXTitleChangedNotification), "and recognised when they arrive")

// What was watched before is still watched.
for name in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
    check(names.contains(name), "\(name) is still watched")
    check(!DockedWindowNotifications.isTitleChange(name), "\(name) is not a title change: the layout is redone for it")
}

check(Set(names).count == names.count, "no notification is asked for twice")
check(!DockedWindowNotifications.isTitleChange(kAXFocusedWindowChangedNotification), "other notifications aren't taken for a title change")
check(!DockedWindowNotifications.isTitleChange(""), "nor an empty name")

if failures == 0 {
    print("docked window checks passed")
} else {
    print("\(failures) docked window check(s) failed")
    exit(1)
}
