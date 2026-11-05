#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
destination="${1:?Usage: build-icon-assets.sh path/to/Contents/Resources}"
catalog_path="$PWD/.build/AppAssets.xcassets"
iconset_path="$catalog_path/PhotoCompressorIcon.appiconset"
mkdir -p "$iconset_path" "$destination"
cp Resources/AppIconContents.json "$iconset_path/Contents.json"
cp .build/AppIcon.iconset/*.png "$iconset_path/"
/usr/bin/xcrun actool "$catalog_path" --compile "$destination" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon PhotoCompressorIcon \
    --output-partial-info-plist "$PWD/.build/AppIconInfo.plist" \
    --output-format human-readable-text --warnings --notices
for icon_key in CFBundleIconFile CFBundleIconName; do
    declared=$(/usr/bin/plutil -extract "$icon_key" raw -expect string -o - Resources/Info.plist)
    compiled=$(/usr/bin/plutil -extract "$icon_key" raw -expect string -o - .build/AppIconInfo.plist)
    if [[ "${declared%.icns}" != "${compiled%.icns}" ]]; then
        print -u2 "App icon metadata does not match the compiled asset catalog: $icon_key"
        exit 1
    fi
done
