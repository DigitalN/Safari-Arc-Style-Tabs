#!/bin/bash
# Runs isolated tests without opening Safari or touching the user's saved state.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/sidetabs-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$TEST_BUILD/module-cache" \
    SideTabs/Models.swift SideTabs/PinnedFolders.swift SideTabs/SpaceState.swift SideTabs/SpaceSwipe.swift \
    SideTabs/TabStore.swift Shared/Bridge.swift Tests/SpaceTests.swift \
    -o "$TEST_BUILD/space-tests"
"$TEST_BUILD/space-tests"
node --check WebExtension/background.js
node Tests/background-tests.cjs WebExtension/background.js
