#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

icon_source="$PWD/Resources/AppIcon.png"
icon_file="$PWD/Resources/AppIcon.icns"
iconset_path="$PWD/.build/AppIcon.iconset"
if [[ -s "$icon_file" && ! "$icon_source" -nt "$icon_file" && -s "$iconset_path/icon_512x512@2x.png" && ! "$icon_source" -nt "$iconset_path/icon_512x512@2x.png" ]]; then
    exit 0
fi

mkdir -p "$iconset_path"
for icon_size in 16 32 128 256 512; do
    /usr/bin/sips -z "$icon_size" "$icon_size" "$icon_source" --out "$iconset_path/icon_${icon_size}x${icon_size}.png" >/dev/null
    retina_size=$((icon_size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" "$icon_source" --out "$iconset_path/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset_path" -o "$icon_file"
