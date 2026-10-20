#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
ROOT="$PWD"
STAGING="$(mktemp -d /tmp/codex-limits-build.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Codex Limits.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGING/icon.iconset" dist
xcrun swiftc scripts/draw-icon.swift -o "$STAGING/draw-icon" -framework AppKit
"$STAGING/draw-icon" "$STAGING/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$STAGING/icon.png" --out "$STAGING/icon.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$STAGING/icon.png" --out "$STAGING/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$STAGING/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$STAGING/icon.png" Resources/AppIcon.png
for arch in x86_64 arm64; do
    xcrun swiftc Sources/main.swift -O -target "${arch}-apple-macosx13.0" -o "$STAGING/CodexLimits-$arch" -framework AppKit -framework ServiceManagement
done
lipo -create "$STAGING/CodexLimits-x86_64" "$STAGING/CodexLimits-arm64" -output "$APP/Contents/MacOS/CodexLimits"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexLimits</string>
<key>CFBundleIdentifier</key><string>io.github.ar1gel.codex-limits</string>
<key>CFBundleName</key><string>Codex Limits</string>
<key>CFBundleDisplayName</key><string>Codex Limits</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/CodexLimits" --self-test
mkdir -p "$STAGING/dmg"
ditto --norsrc --noextattr "$APP" "$STAGING/dmg/Codex Limits.app"
ln -s /Applications "$STAGING/dmg/Applications"
cp LICENSE "$STAGING/dmg/LICENSE.txt"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGING/dmg/.VolumeIcon.icns"
hdiutil create -quiet -volname 'Codex Limits' -srcfolder "$STAGING/dmg" -format UDZO -ov "dist/Codex-Limits-$VERSION-universal.dmg"
ditto --norsrc --noextattr "$APP" 'dist/Codex Limits.app'
(cd dist && shasum -a 256 "Codex-Limits-$VERSION-universal.dmg" > SHA256SUMS)
printf '%s\n' "Built $ROOT/dist/Codex-Limits-$VERSION-universal.dmg"
