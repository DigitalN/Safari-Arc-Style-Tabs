#!/bin/bash
# No browser access or user state. Simulates failed push, retries, and lost replies.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/sidetabs-commands.XXXXXX")
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$TEST_BUILD/module-cache" \
    SideTabs/ExtensionCommandQueue.swift Tests/CommandQueueTests.swift -o "$TEST_BUILD/command-tests"
"$TEST_BUILD/command-tests"
node --check WebExtension/background.js
node Tests/background-tests.cjs WebExtension/background.js
