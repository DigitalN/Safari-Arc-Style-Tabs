#!/bin/bash
# Checks the built app before packaging. Does not launch the app or change permissions.
set -euo pipefail

APP="${1:?usage: verify-app.sh /path/to/Side Tabs.app}"
EXTENSION="$APP/Contents/PlugIns/Side Tabs Extension.appex"

codesign --verify --deep --strict "$APP"
codesign --verify --strict "$EXTENSION"

/usr/bin/python3 - "$APP" "$EXTENSION" <<'PY'
import pathlib
import plistlib
import subprocess
import sys

def require(condition, message):
    if not condition:
        sys.exit("Distribution check failed: " + message)

bundles = [pathlib.Path(path) for path in sys.argv[1:]]
infos, teams = [], []
for bundle, identifier in zip(bundles, ["com.digitaln.sidetabs", "com.digitaln.sidetabs.extension"]):
    with (bundle / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    infos.append(info)
    require(info["CFBundleIdentifier"] == identifier, f"unexpected bundle ID in {bundle.name}")
    binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
    architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).split()
    require(set(architectures) == {"arm64", "x86_64"}, f"{bundle.name} must support Apple silicon and Intel")
    signature = subprocess.run(["/usr/bin/codesign", "-dvv", str(bundle)], capture_output=True, text=True, check=True).stderr
    team = next((line.split("=", 1)[1] for line in signature.splitlines() if line.startswith("TeamIdentifier=")), None)
    require(team and team != "not set", f"{bundle.name} needs a development certificate; do not ship an ad hoc build")
    teams.append(team)
    require("runtime" in signature, f"{bundle.name} must enable hardened runtime")
    print(f"Verified {bundle.name}: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), {' + '.join(architectures)}, team {team}")

require(teams[0] == teams[1], "app and extension signing teams differ")
for key in ["CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion", "SideTabsAppGroup"]:
    require(infos[0].get(key) and infos[0].get(key) == infos[1].get(key), f"app and extension {key} differ or are missing")
require(infos[0]["SideTabsAppGroup"] == teams[0] + ".com.digitaln.sidetabs", "bridge app group doesn't match signing team")
entitlements = plistlib.loads(subprocess.check_output(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundles[1])], stderr=subprocess.DEVNULL))
require(infos[0]["SideTabsAppGroup"] in entitlements.get("com.apple.security.application-groups", []), "extension can't reach the app's message port")
require(entitlements.get("com.apple.security.app-sandbox") is True, "extension sandbox is missing")
print("App and extension versions, minimum macOS and bridge entitlements match.")
PY
