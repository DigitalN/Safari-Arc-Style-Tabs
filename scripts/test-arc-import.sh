#!/bin/bash
# Synthetic fixtures only. --inspect-arc reads the real source but never imports it.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/sidetabs-arc-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$TEST_BUILD/module-cache" \
    SideTabs/ArcMigration.swift SideTabs/Models.swift SideTabs/PinnedFolders.swift \
    SideTabs/SpaceState.swift SideTabs/SpaceSwipe.swift SideTabs/TabStore.swift \
    Shared/Bridge.swift Tests/ArcMigrationTests.swift -o "$TEST_BUILD/arc-tests"
"$TEST_BUILD/arc-tests" "$@"
