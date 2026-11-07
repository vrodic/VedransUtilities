#!/bin/zsh
# Builds a release "Vedran's Utilities.app" in ./build.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
binary="$(swift build -c release --show-bin-path)/VedransUtilities"

app="build/Vedran's Utilities.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/VedransUtilities"

iconset="$(mktemp -d)/AppIcon.iconset"
"$binary" --export-iconset "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vedran's Utilities</string>
    <key>CFBundleDisplayName</key><string>Vedran's Utilities</string>
    <key>CFBundleIdentifier</key><string>com.vedran.utilities</string>
    <key>CFBundleExecutable</key><string>VedransUtilities</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "Built $app"
