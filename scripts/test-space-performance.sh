#!/bin/bash
# Measures row-data preparation against a synthetic imported-sized library.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/sidetabs-performance.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -O -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$TEST_BUILD/module-cache" \
    SideTabs/ArcMigration.swift SideTabs/Models.swift SideTabs/PinnedFolders.swift SideTabs/SpaceState.swift \
    SideTabs/TabStore.swift Shared/Bridge.swift Tests/SpacePerformanceTests.swift \
    -o "$TEST_BUILD/space-performance"
"$TEST_BUILD/space-performance"
