#!/bin/bash
# Pure geometry/state tests: no Safari interaction or real preferences.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/sidetabs-hover-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -swift-version 5 -module-cache-path "$TEST_BUILD/module-cache" \
    SideTabs/SidebarAutoHide.swift Tests/AutoHideTests.swift -o "$TEST_BUILD/hover-tests"
"$TEST_BUILD/hover-tests"
