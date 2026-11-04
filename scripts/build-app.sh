#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/verify-app.sh --plist Resources/Info.plist
./scripts/build-icon.sh
swift build -c release --arch arm64
swift build -c release --arch x86_64
app_path="$PWD/dist/Photo Compressor.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/PhotoCompressor .build/x86_64-apple-macosx/release/PhotoCompressor -output "$app_path/Contents/MacOS/PhotoCompressor.new"
mv -f "$app_path/Contents/MacOS/PhotoCompressor.new" "$app_path/Contents/MacOS/PhotoCompressor"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --sign - --options runtime --entitlements Resources/PhotoCompressor.entitlements "$app_path"
./scripts/verify-app.sh "$app_path"
app_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -expect string -o - "$app_path/Contents/Info.plist")
archive_path="$PWD/dist/Photo Compressor-$app_version.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
cp "$archive_path" "$PWD/dist/Photo Compressor.zip"
print "Built: $app_path"
print "Packaged: $archive_path"
