#!/bin/bash
# No browser access or user state. Exercises polling, retries, and lifecycle guards.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/sidetabs-commands.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$TEST_BUILD/module-cache" \
    SideTabs/ExtensionCommandQueue.swift Tests/CommandQueueTests.swift -o "$TEST_BUILD/command-tests"
"$TEST_BUILD/command-tests"
swiftc -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$TEST_BUILD/module-cache" \
    SideTabs/ExtensionBridge.swift SideTabs/ExtensionCommandQueue.swift Tests/BridgeLifecycleTests.swift \
    -o "$TEST_BUILD/lifecycle-tests"
"$TEST_BUILD/lifecycle-tests"
node --check WebExtension/background.js
node Tests/background-tests.cjs WebExtension/background.js
