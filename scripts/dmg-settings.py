"""Installer layout, matching make-dmg-background.swift (660 × 420 points)."""
from pathlib import Path

application = Path(defines["app"])  # supplied by dmgbuild
files = [str(application)]
symlinks = {"Applications": "/Applications"}
icon = str(application / "Contents/Resources/AppIcon.icns")
background = defines["background"]
format = "UDZO"
compression_level = 9

# Leave room for Finder versions that retain the user’s path/status bar setting.
window_rect = ((200, 120), (660, 480))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
show_icon_preview = False
arrange_by = None
grid_spacing = 90
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 112
icon_locations = {"Side Tabs.app": (170, 205), "Applications": (490, 205)}
