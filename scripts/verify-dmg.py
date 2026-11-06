"""Read-only checks on the final installer, using the isolated packaging environment."""
import pathlib
import plistlib
import subprocess
import sys

from ds_store import DSStore


def require(condition, message):
    if not condition:
        raise RuntimeError("Installer check failed: " + message)


output = subprocess.check_output([
    "/usr/bin/hdiutil", "attach", sys.argv[1], "-nobrowse", "-readonly", "-noautoopen", "-plist"
])
entities = plistlib.loads(output)["system-entities"]
mount = pathlib.Path(next(entity["mount-point"] for entity in entities if "mount-point" in entity))
try:
    visible = {p.name for p in mount.iterdir() if not p.name.startswith(".")}
    require(visible == {"Side Tabs.app", "Applications"}, "unexpected items in the installer")
    require((mount / "Applications").is_symlink(), "Applications shortcut is missing")
    require((mount / "Applications").readlink() == pathlib.Path("/Applications"), "wrong Applications shortcut")
    require((mount / ".background.tiff").is_file(), "installer artwork is missing")
    with DSStore.open(str(mount / ".DS_Store"), "r") as store:
        window = store["."][b"bwsp"]
        require(window["WindowBounds"] == "{{200, 120}, {660, 480}}", "window size differs from the artwork")
        require(not any(window.get(key, False) for key in ["ShowStatusBar", "ShowToolbar", "ShowSidebar", "ShowPathbar", "ShowTabView"]), "extra Finder chrome obscures the instructions")
        require(store["Side Tabs.app"][b"Iloc"] == (170, 205), "app icon moved")
        require(store["Applications"][b"Iloc"] == (490, 205), "Applications icon moved")
    subprocess.run(["scripts/verify-app.sh", str(mount / "Side Tabs.app")], check=True)
    print("Verified installer contents, Applications shortcut, artwork and saved window layout.")
finally:
    subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], check=True, stdout=subprocess.DEVNULL)
