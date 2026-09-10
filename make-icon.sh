#!/bin/sh
# Regenerates Icon/AppIcon.icns from Icon/icon-1024.png using Apple's own
# tools. Only needed if you change the artwork; the .icns is committed.
set -eu

SRC="Icon/icon-1024.png"
SET="Icon/AppIcon.iconset"

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

rm -rf "$SET"
mkdir -p "$SET"

for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  px=$(echo "$spec" | cut -d' ' -f1)
  name=$(echo "$spec" | cut -d' ' -f2)
  sips -z "$px" "$px" "$SRC" --out "$SET/icon_$name.png" >/dev/null
done

iconutil -c icns "$SET" -o Icon/AppIcon.icns
rm -rf "$SET"
echo "wrote Icon/AppIcon.icns"
