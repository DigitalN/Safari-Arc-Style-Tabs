#!/bin/bash
# Builds Side Tabs, installs it in /Applications and launches it.
#
#   scripts/install.sh            sign with your Apple Development certificate
#   scripts/install.sh --adhoc    sign locally only (Safari then needs
#                                 Develop → Allow Unsigned Extensions after every restart)

set -euo pipefail
cd "$(dirname "$0")/.."

# Build outside the repo: folders synced by iCloud Drive (like ~/Documents) add
# Finder metadata to app bundles, which codesign rejects.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/SideTabs-CLI"
BUILT="$DERIVED/Build/Products/Release/Side Tabs.app"
DEST="/Applications/Side Tabs.app"
LOG="$DERIVED/build.log"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

team_id() {
    # Use the first *valid* Apple Development identity (expired certificates stay in the
    # keychain); its team id is the OU field of the certificate.
    local hash
    hash=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ {print $2; exit}')
    [[ -n "$hash" ]] || return 0
    security find-certificate -a -Z -p -c "Apple Development" 2>/dev/null \
        | awk -v hash="$hash" '/^SHA-1 hash:/ {take = ($3 == hash)} take' \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p'
}

if [[ "${1:-}" == "--adhoc" ]]; then
    SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
    echo "Signing locally (ad hoc)."
else
    TEAM="${TEAM_ID:-$(team_id)}"
    if [[ -z "$TEAM" ]]; then
        cat >&2 <<'EOF'
No valid Apple Development certificate found. A free Apple ID is enough:

  1. Open Xcode → Settings → Accounts and sign in with your Apple ID.
  2. Select your "(Personal Team)", click "Manage Certificates…", then + → "Apple Development".
  3. Run this script again.

(Or run with --adhoc to skip signing; Safari will then turn the extension off
every time it restarts until you re-enable Develop → Allow Unsigned Extensions.)
EOF
        exit 1
    fi
    SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Apple Development" DEVELOPMENT_TEAM="$TEAM" PROVISIONING_PROFILE_SPECIFIER=)
    echo "Signing with team $TEAM."
fi

mkdir -p "$DERIVED"
echo "Building…"
if ! xcodebuild \
    -project SideTabs.xcodeproj \
    -scheme "Side Tabs" \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    "${SIGNING[@]}" \
    build >"$LOG" 2>&1; then
    grep -E "error:|failed" "$LOG" | head -20 >&2
    echo "Build failed; full log: $LOG" >&2
    exit 1
fi

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
