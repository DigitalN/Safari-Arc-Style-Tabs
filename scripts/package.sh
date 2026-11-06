#!/bin/bash
# Build a universal, development-signed app and package dist/Side-Tabs.dmg.
# Layout metadata is written directly; Finder and Automation permission aren't needed.
set -euo pipefail
cd "$(dirname "$0")/.."

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUILT=$(scripts/build.sh "$@")
scripts/verify-app.sh "$BUILT" >&2
# Keep the build product from showing up in Safari as a second extension.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true

# Only the maintainer needs these packaging tools. Friends just open the finished DMG.
PACKAGING_ENV="${SIDETABS_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/SideTabs-CLI}/packaging-env"
if [[ ! -x "$PACKAGING_ENV/bin/python" ]]; then
    python3 -m venv "$PACKAGING_ENV"
fi
PYTHON="$PACKAGING_ENV/bin/python"
if ! "$PYTHON" -c 'import importlib.metadata as m; assert all(m.version(n) == v for n, v in [("dmgbuild", "1.6.7"), ("ds_store", "1.3.3"), ("mac_alias", "2.2.3")])' 2>/dev/null; then
    "$PYTHON" -m pip install --disable-pip-version-check -r scripts/package-requirements.txt >&2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sidetabs-dmg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

echo "Drawing the installer background…" >&2
swift scripts/make-dmg-background.swift "$WORK/background.tiff"

echo "Packaging the disk image…" >&2
mkdir -p dist
# Build to a temporary file so a failed packaging run leaves the last good DMG intact.
"$PYTHON" -m dmgbuild -s scripts/dmg-settings.py \
    -D "app=$BUILT" -D "background=$WORK/background.tiff" \
    "Side Tabs" "$WORK/Side-Tabs.dmg" >&2

# Catch unexpected layout defaults before handing the image to someone else.
"$PYTHON" scripts/verify-dmg.py "$WORK/Side-Tabs.dmg" >&2
mv -f "$WORK/Side-Tabs.dmg" dist/Side-Tabs.dmg
echo "dist/Side-Tabs.dmg"
