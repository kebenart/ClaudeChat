#!/bin/bash
# Package the SwiftPM ClaudeChat executable into a proper .app bundle so it has
# a bundle id (notifications work), a Dock/Finder icon, and is double-clickable.
set -eo pipefail
cd "$(dirname "$0")/.."   # apple/

CONFIG="${1:-release}"
APP="build/ClaudeChat.app"
ICON_PNG="Sources/ClaudeChat/AppIcon.png"
BUNDLE_ID="com.kebenart.claudechat.mac"

echo "Building ($CONFIG)..."
swift build -c "$CONFIG" >/dev/null
BIN_DIR=".build/$CONFIG"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ClaudeChat" "$APP/Contents/MacOS/ClaudeChat"
# NOTE: no SwiftPM resource .bundle is copied in — a nested bare .bundle breaks
# the app's code signature, which stops macOS from registering notifications.

echo "Generating AppIcon.icns..."
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ClaudeChat</string>
  <key>CFBundleDisplayName</key><string>Claude Chat</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>ClaudeChat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST

echo "Ad-hoc codesigning..."
# No nested bundles now, so a single deep sign produces a valid signature
# (required for macOS to register the app for notifications).
codesign --force --deep --sign - "$APP"
echo "Verifying signature..."
codesign --verify --verbose=1 "$APP" && echo "  signature OK" || echo "  WARN signature invalid"

echo "Built $APP"
echo "Run it with:  open $(pwd)/$APP"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
