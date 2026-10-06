#!/bin/bash
# Builds Side Tabs, installs it in /Applications and launches it.
#
#   scripts/install.sh            sign with your Apple Development certificate
#   scripts/install.sh --adhoc    sign locally only (Safari then needs
#                                 Develop → Allow Unsigned Extensions after every restart)

set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/Side Tabs.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

BUILT=$(scripts/build.sh "$@")

echo "Installing to $DEST…"
osascript -e 'tell application id "com.digitaln.sidetabs" to quit' >/dev/null 2>&1 || true
pkill -x "Side Tabs" >/dev/null 2>&1 || true
sleep 0.5
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

# Make sure Safari only sees the installed copy of the extension.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
pluginkit -r "$BUILT/Contents/PlugIns/Side Tabs Extension.appex" >/dev/null 2>&1 || true
"$LSREGISTER" -f -R "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/Side Tabs Extension.appex" >/dev/null 2>&1 || true

open "$DEST"
echo "Done. Side Tabs is running (look for the sidebar icon in the menu bar)."
