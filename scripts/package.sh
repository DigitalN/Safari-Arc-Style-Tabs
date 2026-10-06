#!/bin/bash
# Builds Side Tabs and packages it for a GitHub release:
#   dist/Side-Tabs-<version>.dmg   what people download. When opened, it shows Side Tabs
#                                  and the Applications folder with an arrow between them.
#   dist/Side-Tabs-<version>.zip   what the app's built-in updater downloads.
# Attach both to a release tagged v<version>.
#
# Finder lays out the window, so the first run asks to let Terminal control Finder.

set -euo pipefail
cd "$(dirname "$0")/.."

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
VOLUME_NAME="Side Tabs"

BUILT=$(scripts/build.sh "$@")
# Keep the build product from showing up in Safari as a second copy of the extension.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$BUILT/Contents/Info.plist")
DMG="dist/Side-Tabs-$VERSION.dmg"
ZIP="dist/Side-Tabs-$VERSION.zip"

# Work outside the repo, which may be synced by iCloud Drive (see build.sh).
WORK="$HOME/Library/Developer/Xcode/DerivedData/SideTabs-CLI/dmg"
rm -rf "$WORK"
mkdir -p "$WORK/source/.background"
ditto "$BUILT" "$WORK/source/Side Tabs.app"
ln -s /Applications "$WORK/source/Applications"
echo "Drawing the window background…" >&2
swift scripts/make-dmg-background.swift "$WORK/source/.background/background.tiff"

echo "Laying out the window…" >&2
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$WORK/source" -fs HFS+ \
    -format UDRW -size 40m -ov "$WORK/layout.dmg"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/layout.dmg" | grep -o '/Volumes/.*$')
DISK=$(basename "$MOUNT")
detach() { hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true; }
trap detach EXIT

# Icon positions match the arrow in make-dmg-background.swift: a 660 × 420 pt window
# with icon centers at x = 170 and x = 490.
if ! osascript <<EOF
tell application "Finder"
    tell disk "$DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 568}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set label position of viewOptions to bottom
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to false
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Side Tabs.app" of container window to {170, 205}
        set position of item "Applications" of container window to {490, 205}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
then
    echo "Finder couldn't lay out the window. If macOS asked, allow Terminal to control Finder" >&2
    echo "(System Settings → Privacy & Security → Automation), then run this again." >&2
    exit 1
fi

# Wait for Finder to save the layout before detaching.
for _ in $(seq 1 20); do
    [[ -f "$MOUNT/.DS_Store" ]] && break
    sleep 0.25
done

# Show the Side Tabs icon on the mounted disk. Added after the layout step because Finder
# removes .VolumeIcon.icns while it arranges the window.
cp "$BUILT/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
rm -rf "$MOUNT/.fseventsd"
sync
detach
trap - EXIT

mkdir -p dist
rm -f "$DMG"
hdiutil convert -quiet "$WORK/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$WORK"

rm -f "$ZIP"
ditto -c -k --keepParent "$BUILT" "$ZIP"

echo "$DMG"
echo "$ZIP"
