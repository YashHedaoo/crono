#!/bin/bash
# render-outfits.sh — compile and run the Mochi outfit planche renderer
# NOT in CI. Run manually: bash scripts/render-outfits.sh
# Output: /tmp/crono-outfits.png

set -e
cd "$(dirname "$0")/.."

SDK=$(xcrun --sdk macosx --show-sdk-path)

echo "Compiling renderer..."
swiftc \
  -parse-as-library \
  -sdk "$SDK" \
  -target arm64-apple-macosx15.0 \
  NotchBuddy/Sources/CronoKit/IslandScreenGeometry.swift \
  NotchBuddy/Sources/CronoKit/IslandTypes.swift \
  NotchBuddy/Sources/CronoKit/MochiWardrobe.swift \
  NotchBuddy/Sources/CronoKit/BotEngine.swift \
  NotchBuddy/Sources/CronoKit/MochiOutfitDrawing.swift \
  scripts/RenderOutfits.swift \
  -framework AppKit \
  -framework SwiftUI \
  -o /tmp/crono-render-outfits \
  2>&1

echo "Running renderer..."
/tmp/crono-render-outfits
echo "Opening..."
open /tmp/crono-outfits.png
