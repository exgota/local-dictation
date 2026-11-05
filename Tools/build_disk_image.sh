#!/bin/sh
# Builds the release disk image: Local Dictation beside an Applications shortcut, on the Moonrise background.
# Usage: Tools/build_disk_image.sh "<path to Local Dictation.app>" <output .dmg>
# Needs python3 and the network the first time, to install the pinned dmgbuild into .build/disk-image-tools.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
application=$1
output=$2
tools="$root/.build/disk-image-tools"
if [ ! -x "$tools/bin/dmgbuild" ]; then
    python3 -m venv "$tools"
    "$tools/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==1.6.7" "ds_store==1.3.3" "mac_alias==2.2.3"
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# One TIFF holding the 1x and 2x art, so Finder draws the background sharp on Retina displays.
tiffutil -cathidpicheck "$root/Packaging/DiskImageBackground.png" "$root/Packaging/DiskImageBackground@2x.png" \
    -out "$work/background.tiff" >/dev/null
cat > "$work/settings.py" <<EOF
files = [$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$application")]
symlinks = {"Applications": "/Applications"}
background = "$work/background.tiff"
window_rect = ((200, 200), (640, 400))
icon_size = 128
text_size = 12
icon_locations = {"Local Dictation.app": (176, 190), "Applications": (464, 190)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
format = "UDZO"
EOF
rm -f "$output"
"$tools/bin/dmgbuild" -s "$work/settings.py" "Local Dictation" "$output"
hdiutil verify -quiet "$output"
echo "$output"
