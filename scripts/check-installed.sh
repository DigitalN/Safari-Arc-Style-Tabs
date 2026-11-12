#!/bin/bash
# Checks that the only copy of Side Tabs on this Mac is the one in /Applications: no development copy left
# behind by a build or a test (#67). Commands from the app only reach the extension inside it, so when Safari
# runs another copy's extension, which it can after a restart, the sidebar's commands do nothing.
#
#   scripts/check-installed.sh
#
# It checks that:
#   - no Side Tabs app or extension is on disk outside /Applications/Side Tabs.app
#   - pluginkit lists the extension inside /Applications/Side Tabs.app, and no other copy
#   - LaunchServices has no record of another copy that still exists on disk (records of paths that are gone,
#     like an ejected disk image's, are fine)
#   - no UpdateFeedURL default is set, which only updater tests use
#
# It only reads: it never changes, registers or deletes anything, and doesn't check which version
# /Applications holds. Exits 1 if any check fails.
#
# The disk search covers the home folder, /private/tmp, /Applications and mounted disk images, plus Spotlight
# by bundle id. It leaves out folders where looking makes macOS ask for permission (Desktop, Documents,
# Downloads, media folders, other apps' containers, cloud storage) and volumes other than disk images
# (external disks would ask too): Spotlight covers those.

set -uo pipefail

APP="/Applications/Side Tabs.app"
APP_EXTENSION="$APP/Contents/PlugIns/Side Tabs Extension.appex"
APP_ID=com.digitaln.sidetabs
EXTENSION_ID=com.digitaln.sidetabs.extension
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

failed=0
fail() {
    echo "FAIL: $*"
    failed=1
}

# Whether a path is the installed copy or inside it.
installed() {
    [[ "$1" == "$APP" || "$1" == "$APP/"* ]]
}

is_side_tabs() {
    local id
    id=$(plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null) || return 1
    [[ "$id" == "$APP_ID" || "$id" == "$EXTENSION_ID" ]]
}

# Bundles under a folder, without looking inside them (`-prune`), and without the folders in $SKIP.
bundles() {
    local root="$1"
    shift
    local skip=()
    for path in "$@"; do
        skip+=(-path "$path" -o)
    done
    if ((${#skip[@]})); then
        find "$root" \( "${skip[@]}" -false \) -prune -o \( -name '*.app' -o -name '*.appex' \) -type d -print -prune 2>/dev/null
    else
        find "$root" \( -name '*.app' -o -name '*.appex' \) -type d -print -prune 2>/dev/null
    fi
}

echo "== copies on disk"
candidates=$(
    bundles "$HOME" \
        "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads" "$HOME/Movies" "$HOME/Music" "$HOME/Pictures" \
        "$HOME/Library/Containers" "$HOME/Library/Group Containers" "$HOME/Library/Daemon Containers" \
        "$HOME/Library/CloudStorage" "$HOME/Library/Mobile Documents"
    bundles /private/tmp
    find /Applications -maxdepth 2 \( -name '*.app' -o -name '*.appex' \) -type d -print -prune 2>/dev/null
    # Mounted disk images, the app on one among them.
    hdiutil info 2>/dev/null | awk -F'\t' '$NF ~ /^\/Volumes\// { print $NF }' | while IFS= read -r volume; do
        bundles "$volume"
    done
    mdfind "kMDItemCFBundleIdentifier == '$APP_ID' || kMDItemCFBundleIdentifier == '$EXTENSION_ID'" 2>/dev/null
)
found=0
while IFS= read -r bundle; do
    [[ -n "$bundle" && -e "$bundle" ]] || continue
    installed "$bundle" && continue
    is_side_tabs "$bundle" || continue
    fail "a copy of Side Tabs at $bundle"
    found=1
done < <(printf '%s\n' "$candidates" | sort -u)
((found)) || echo "only $APP"

echo "== pluginkit"
listed=$(pluginkit -m -A -D -v -i "$EXTENSION_ID" 2>/dev/null | awk -F'\t' 'NF > 1 && $NF ~ /\.appex$/ { print $NF }')
if [[ -z "$listed" ]]; then
    if [[ -d "$APP" ]]; then
        fail "pluginkit lists no Side Tabs extension, so Safari doesn't see the one in $APP"
    else
        fail "pluginkit lists no Side Tabs extension, and $APP isn't there"
    fi
else
    while IFS= read -r extension; do
        [[ "$extension" == "$APP_EXTENSION" ]] || fail "pluginkit lists another copy of the extension: $extension"
    done <<< "$listed"
    [[ "$listed" == "$APP_EXTENSION" ]] && echo "only $APP_EXTENSION"
fi

echo "== LaunchServices"
# Each record in the dump is a block of "field: value" lines between lines of dashes; a path ends with its id
# in parentheses.
records=$("$LSREGISTER" -dump 2>/dev/null | awk -v app="$APP_ID" -v ext="$EXTENSION_ID" '
    function emit() { if ((id == app || id == ext) && path != "") print path; id = ""; path = "" }
    /^-----------------/ { emit(); next }
    /^path:/ { path = $0; sub(/^path:[ \t]*/, "", path); sub(/ \(0x[0-9a-fA-F]+\)$/, "", path) }
    /^identifier:/ { id = $0; sub(/^identifier:[ \t]*/, "", id) }
    END { emit() }
')
others=0
while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    installed "$path" && continue
    [[ -e "$path" ]] || continue
    fail "LaunchServices has a record of another copy that's still there: $path"
    others=1
done < <(printf '%s\n' "$records" | sort -u)
((others)) || echo "no record of another copy that's still on disk"

echo "== updater test feed"
if feed=$(defaults read "$APP_ID" UpdateFeedURL 2>/dev/null); then
    fail "UpdateFeedURL is set ($feed); remove it with: defaults delete $APP_ID UpdateFeedURL"
else
    echo "no UpdateFeedURL"
fi

if ((failed)); then
    echo "This Mac has development copies of Side Tabs, or its install isn't registered."
    exit 1
fi
echo "Only the copy in /Applications."
