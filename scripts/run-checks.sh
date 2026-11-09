#!/bin/bash
# Runs the logic checks that don't need Safari: the extension's scheduling and message
# ordering (node), and the Swift logic compiled together with small test programs.
# Nothing here touches the installed app, Safari, or your Side Tabs data.
#
#   scripts/run-checks.sh

set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== background.js"
node --check WebExtension/background.js
node Tests/ExtensionChecks/background-checks.js

# The store checks give each TabStore a state file in a temporary folder, so nothing here
# reads or writes the real one in ~/Library/Application Support/Side Tabs.
echo "== TabStore"
swiftc -o "$WORK/store-checks" \
    Tests/StoreChecks/main.swift SideTabs/TabStore.swift SideTabs/Models.swift SideTabs/TabBarMatcher.swift \
    SideTabs/BookmarkTabs.swift Shared/Bridge.swift SideTabs/TabCleanup.swift \
    SideTabs/BookmarkLists.swift SideTabs/ProfileKey.swift
"$WORK/store-checks"

# Which tabs cleanup closes, the clocks it keeps, its list of closed tabs and reopening them (#27).
# Like the store checks, every store here keeps its state in a temporary folder.
echo "== tab cleanup"
swiftc -o "$WORK/cleanup-checks" \
    Tests/TabCleanupChecks/main.swift SideTabs/TabCleanup.swift SideTabs/TabStore.swift SideTabs/Models.swift \
    SideTabs/TabBarMatcher.swift SideTabs/AppSettings.swift SideTabs/BookmarkTabs.swift Shared/Bridge.swift \
    SideTabs/BookmarkLists.swift SideTabs/ProfileKey.swift
"$WORK/cleanup-checks"

echo "== click actions"
swiftc -o "$WORK/click-checks" \
    Tests/ClickActionsChecks/main.swift SideTabs/ClickActions.swift SideTabs/AccessibilityQuery.swift Shared/Bridge.swift
"$WORK/click-checks"

echo "== tab bar matcher"
swiftc -o "$WORK/matcher-checks" Tests/TabBarMatcherChecks/main.swift SideTabs/TabBarMatcher.swift
"$WORK/matcher-checks"

echo "== tab bar finder"
swiftc -o "$WORK/finder-checks" \
    Tests/TabBarFinderChecks/main.swift SideTabs/TabBarFinder.swift SideTabs/TabBarMatcher.swift
"$WORK/finder-checks"

# Which of Safari's windows the sidebar docks to: browser windows only, never Settings and the like
# (#32). Uses the recorded trees in Tests/TabBarFinderChecks/trees.
echo "== browser windows"
swiftc -o "$WORK/browser-window-checks" Tests/BrowserWindowChecks/main.swift SideTabs/BrowserWindowRule.swift
"$WORK/browser-window-checks"

echo "== row hit testing"
swiftc -o "$WORK/row-hit-checks" Tests/RowHitChecks/main.swift SideTabs/RowHitTesting.swift SideTabs/Models.swift
"$WORK/row-hit-checks"

echo "== row press"
swiftc -o "$WORK/row-press-checks" Tests/RowPressChecks/main.swift SideTabs/RowPress.swift
"$WORK/row-press-checks"

# When Settings recommends the Mac's "Minimize windows into application icon" option (#42): only while
# "Minimize other profiles' windows" is on and the option is off. The rule only; nothing reads this Mac's Dock.
echo "== dock recommendation"
swiftc -o "$WORK/dock-recommendation-checks" Tests/DockRecommendationChecks/main.swift SideTabs/DockMinimizeOption.swift
"$WORK/dock-recommendation-checks"

echo "== docked window notifications"
swiftc -o "$WORK/docked-window-checks" Tests/DockedWindowChecks/main.swift SideTabs/DockedWindowNotifications.swift
"$WORK/docked-window-checks"

echo "== sidebar overlay"
swiftc -o "$WORK/overlay-checks" Tests/SidebarOverlayChecks/main.swift SideTabs/SidebarOverlay.swift \
    SideTabs/SafariBars.swift SideTabs/TabBarFinder.swift SideTabs/TabBarMatcher.swift
"$WORK/overlay-checks"

# Safari's profiles (#33): their identifiers in File → New Window and each window's toolbar, found in
# trees #28 recorded; keeping the list and profiles.json; which profile a window is in, which extension
# copy is a profile's, when Side Tabs counts as off in a profile, and which window a switch brings forward.
# Also where the profile buttons go in the bottom bar, and when a dropdown takes their place (#39).
echo "== profiles"
swiftc -o "$WORK/profile-checks" \
    Tests/ProfileChecks/main.swift SideTabs/ProfileKey.swift SideTabs/SafariProfile.swift \
    SideTabs/ProfileTree.swift SideTabs/ProfileRules.swift SideTabs/ProfileBarLayout.swift
"$WORK/profile-checks"

# "Minimize other profiles' windows" (#42): the current profile, which windows a change of profile minimizes and
# which come back, in what order, which window a switch brings forward, the list of windows Side Tabs minimized,
# saving it and matching it after a restart, and when a click on Safari's Dock icon opens a window in the current
# profile.
echo "== minimizing other profiles' windows"
swiftc -o "$WORK/minimize-checks" \
    Tests/MinimizeChecks/main.swift SideTabs/MinimizeRules.swift SideTabs/ProfileRules.swift \
    SideTabs/SafariProfile.swift SideTabs/ProfileKey.swift
"$WORK/minimize-checks"
# A profile's name is the user's own words, so it stays out of the log like titles and URLs do.
# Positions, symbols and the copy's profile UUID are fine.
if grep -nE '(\blog\.(notice|info|error|debug|warning|fault)|\bnote)\(.*\\\([^)]*\b(name|names|profileName|rowName)\b' \
    SideTabs/*.swift SideTabs/Views/*.swift; then
    echo "FAIL: a log line carries a profile's name; log its position instead"
    exit 1
fi
echo "no profile names in the log"

# A window the extension can't see (#41): its tabs read from its tab bar, in order, with the selected one,
# its tab buttons' close actions, and presses made from what was read, against the recorded trees.
echo "== windows Safari doesn't share"
swiftc -o "$WORK/unseen-checks" \
    Tests/UnseenWindowChecks/main.swift SideTabs/TabBarFinder.swift SideTabs/TabBarMatcher.swift
"$WORK/unseen-checks"

# A row has one mouse gesture, the one sidebarRowGesture attaches. A press gesture of its own,
# inside the reorder gesture, wins every press and the reorder never starts (#20).
# How the favorites' grid lays out tiles, at every width SwiftUI proposes (#34).
echo "== tile grid"
swiftc -o "$WORK/tile-grid-checks" Tests/TileGridChecks/main.swift SideTabs/TileGridMetrics.swift
"$WORK/tile-grid-checks"

echo "== row gestures"
if grep -n "DragGesture" SideTabs/Views/TabRow.swift SideTabs/Views/BookmarkRow.swift SideTabs/Views/FavoritesSection.swift; then
    echo "FAIL: rows must not attach a DragGesture of their own; use sidebarRowGesture (SidebarDrag.swift)"
    exit 1
fi
echo "rows have no gesture of their own"

# A window's title is the page's, and a tab's title is too, so neither goes into the system log: it
# would keep browsing history in plain text (#22 item 5). Lengths and counts are fine.
echo "== log privacy"
if grep -nE '(\blog\.(notice|info|error|debug|warning|fault)|\bnote)\(.*[Tt]itle' SideTabs/*.swift \
    || grep -nE '\\\(.*kAXTitleAttribute' SideTabs/*.swift; then
    echo "FAIL: a log line carries a window or tab title; leave it out or log only its length"
    exit 1
fi
echo "no titles in the log"
# Nor a page's address, which is browsing history too. Cleanup's list of closed tabs holds both, and
# they belong in state.json only (#27).
if grep -nE '(\blog\.(notice|info|error|debug|warning|fault)|\bnote)\(.*\\\([^)]*\b(url|URL|urls|faviconURL|favIconUrl)\b' \
    SideTabs/*.swift SideTabs/Views/*.swift; then
    echo "FAIL: a log line carries a page's URL; leave it out"
    exit 1
fi
echo "no URLs in the log"

# A quick compile check of the app's Swift sources (no signing, no packaging). The full
# build is scripts/build.sh.
echo "== app sources"
# The same upcoming feature as the app target (SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY), so a
# file that uses a module it doesn't import fails here, as it does in Xcode.
swiftc -typecheck -swift-version 5 -default-isolation MainActor -enable-upcoming-feature MemberImportVisibility \
    -target arm64-apple-macosx26.0 -parse-as-library \
    SideTabs/*.swift SideTabs/Views/*.swift Shared/Bridge.swift
