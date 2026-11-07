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

# TabStore reads and may write ~/Library/Application Support/Side Tabs; point HOME at an
# empty folder so the checks can't touch the real file.
echo "== TabStore"
swiftc -o "$WORK/store-checks" \
    Tests/StoreChecks/main.swift SideTabs/TabStore.swift SideTabs/Models.swift Shared/Bridge.swift
HOME="$WORK" "$WORK/store-checks"

echo "== click actions"
swiftc -o "$WORK/click-checks" \
    Tests/ClickActionsChecks/main.swift SideTabs/ClickActions.swift SideTabs/AccessibilityQuery.swift Shared/Bridge.swift
"$WORK/click-checks"

# A quick compile check of the app's Swift sources (no signing, no packaging). The full
# build is scripts/build.sh.
echo "== app sources"
swiftc -typecheck -swift-version 5 -default-isolation MainActor -target arm64-apple-macosx26.0 -parse-as-library \
    SideTabs/*.swift SideTabs/Views/*.swift Shared/Bridge.swift
