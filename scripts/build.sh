#!/bin/bash
# Builds a signed Release copy of Side Tabs and prints the path to the .app.
# Used by install.sh and package.sh.
#
#   scripts/build.sh            sign with your Apple Development certificate
#   scripts/build.sh --adhoc    sign locally only (Safari then needs
#                               Develop → Allow Unsigned Extensions after every restart)

set -euo pipefail
cd "$(dirname "$0")/.."

# Build outside the repo: folders synced by iCloud Drive (like ~/Documents) add
# Finder metadata to app bundles, which codesign rejects.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/SideTabs-CLI"
BUILT="$DERIVED/Build/Products/Release/Side Tabs.app"
LOG="$DERIVED/build.log"

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
    echo "Signing locally (ad hoc)." >&2
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
    echo "Signing with team $TEAM." >&2
fi

mkdir -p "$DERIVED"
echo "Building…" >&2
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

echo "$BUILT"
