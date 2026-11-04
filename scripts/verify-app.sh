#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == "--plist" ]]; then
    plist_path="${2:?Usage: verify-app.sh --plist path/to/Info.plist}"
    app_path=""
else
    app_path="${1:?Usage: verify-app.sh path/to/application.app}"
    plist_path="$app_path/Contents/Info.plist"
fi

/usr/bin/plutil -lint "$plist_path"
for usage_key in NSPhotoLibraryUsageDescription NSAppleEventsUsageDescription; do
    if ! usage_description=$(/usr/bin/plutil -extract "$usage_key" raw -expect string -o - "$plist_path") || [[ -z "${usage_description//[[:space:]]/}" ]]; then
        print -u2 "Missing or empty privacy usage description: $usage_key in $plist_path"
        exit 1
    fi
done

if [[ -n "$app_path" ]]; then
    executable_name=$(/usr/bin/plutil -extract CFBundleExecutable raw -expect string -o - "$plist_path")
    icon_name=$(/usr/bin/plutil -extract CFBundleIconFile raw -expect string -o - "$plist_path")
    if [[ ! -s "$app_path/Contents/Resources/$icon_name" ]]; then
        print -u2 "Missing app icon: $icon_name"
        exit 1
    fi
    /usr/bin/lipo "$app_path/Contents/MacOS/$executable_name" -verify_arch arm64 x86_64
    /usr/bin/codesign --verify --strict --verbose=2 "$app_path"
fi
