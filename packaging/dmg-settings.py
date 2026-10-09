# dmgbuild settings: the installer window. Positions are icon centres in points and must match
# the layout drawn by packaging/make-assets.swift (720x440 content area).
import os

app = defines["app"]
files = [app, defines["readme"]]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
format = "UDZO"
# Title bar and an optional path bar add up to about 56 pt on top of the content area.
window_rect = ((240, 180), (720, 496))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 96
text_size = 12
icon_locations = {
    os.path.basename(app): (180, 196),
    "Applications": (540, 196),
    os.path.basename(defines["readme"]): (360, 352),
}
