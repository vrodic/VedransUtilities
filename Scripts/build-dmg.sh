#!/bin/zsh
# Builds the release app and packages it as a drag-to-install disk image in ./build.
set -euo pipefail

cd "$(dirname "$0")/.."
./Scripts/build-app.sh

name="Vedran's Utilities"
app="build/$name.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="build/VedransUtilities-$version.dmg"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
# ditto keeps the bundle's signature and metadata intact.
ditto "$app" "$staging/$name.app"
ln -s /Applications "$staging/Applications"

rm -f "$dmg"
hdiutil create -quiet -volname "$name" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify -quiet "$dmg"
echo "Built $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '))"
