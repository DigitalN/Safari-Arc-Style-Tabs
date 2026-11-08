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
    SideTabs/BookmarkTabs.swift Shared/Bridge.swift
"$WORK/store-checks"

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

echo "== row hit testing"
swiftc -o "$WORK/row-hit-checks" Tests/RowHitChecks/main.swift SideTabs/RowHitTesting.swift SideTabs/Models.swift
"$WORK/row-hit-checks"

echo "== row press"
swiftc -o "$WORK/row-press-checks" Tests/RowPressChecks/main.swift SideTabs/RowPress.swift
"$WORK/row-press-checks"

echo "== docked window notifications"
swiftc -o "$WORK/docked-window-checks" Tests/DockedWindowChecks/main.swift SideTabs/DockedWindowNotifications.swift
"$WORK/docked-window-checks"

# A row has one mouse gesture, the one sidebarRowGesture attaches. A press gesture of its own,
# inside the reorder gesture, wins every press and the reorder never starts (#20).
echo "== row gestures"
if grep -n "DragGesture" SideTabs/Views/TabRow.swift SideTabs/Views/BookmarkRow.swift; then
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

# A quick compile check of the app's Swift sources (no signing, no packaging). The full
# build is scripts/build.sh.
echo "== app sources"
swiftc -typecheck -swift-version 5 -default-isolation MainActor -target arm64-apple-macosx26.0 -parse-as-library \
    SideTabs/*.swift SideTabs/Views/*.swift Shared/Bridge.swift
