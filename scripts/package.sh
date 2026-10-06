#!/bin/bash
# Builds Side Tabs and packages it as a disk image for sharing:
#   dist/Side-Tabs-<version>.dmg
# containing the app, a shortcut to Applications to drag it onto, and short
# install instructions. Attach the .dmg to a GitHub release.

set -euo pipefail
cd "$(dirname "$0")/.."

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

BUILT=$(scripts/build.sh "$@")
# Keep the build product from showing up in Safari as a second copy of the extension.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
DMG="dist/Side-Tabs-$VERSION.dmg"

# Stage outside the repo, which may be synced by iCloud Drive (see build.sh).
STAGING="$HOME/Library/Developer/Xcode/DerivedData/SideTabs-CLI/dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$BUILT" "$STAGING/Side Tabs.app"
ln -s /Applications "$STAGING/Applications"
cp "scripts/How to Install.txt" "$STAGING/How to Install.txt"

mkdir -p dist
rm -f "$DMG"
echo "Creating $DMG…" >&2
hdiutil create -quiet -volname "Side Tabs $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGING"

echo "$DMG"
