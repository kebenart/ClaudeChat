#!/bin/bash
# Regenerate the watchOS AppIcon asset from the unified source icon.
# watchOS (Xcode 14+) accepts a single 1024² universal app icon, same as iOS.
# App icons must be OPAQUE, so the alpha channel is flattened onto white.
set -eo pipefail
cd "$(dirname "$0")/.."   # apple/

SRC="Sources/ClaudeChat/AppIcon.png"            # 2048×2048 unified source of truth
DEST="watch/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

echo "Generating watch AppIcon (1024×1024) from $SRC..."
mkdir -p "$(dirname "$DEST")"
sips -s format png -z 1024 1024 "$SRC" --out "$DEST" >/dev/null

# Strip transparency — app icons must be opaque or actool warns/rejects.
if command -v magick >/dev/null 2>&1; then
  magick "$DEST" -background white -alpha remove -alpha off "$DEST"
elif command -v convert >/dev/null 2>&1; then
  convert "$DEST" -background white -alpha remove -alpha off "$DEST"
else
  echo "  WARN: ImageMagick not found; icon may retain an alpha channel"
fi

echo "done -> $DEST"
