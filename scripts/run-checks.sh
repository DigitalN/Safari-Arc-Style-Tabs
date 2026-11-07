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
