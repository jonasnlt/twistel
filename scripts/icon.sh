#!/usr/bin/env bash
# Builds the app icon (Icon/AppIcon.icon) and the accent color (Icon/Farben.xcassets) into Resources/Assets.car and Resources/AppIcon.icns.
# Only needed when the icon or the color changes. Needs Xcode, but only for this one call of actool (through DEVELOPER_DIR);
# xcode-select stays on the Command Line Tools, and the app is still built without Xcode (scripts/build.sh uses the finished files).
set -euo pipefail
cd "$(dirname "$0")/.."
XCODE="${XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

echo "==> Layers as SVG"
mkdir -p .build/icon
SDKROOT="$SDK" swiftc -o .build/icon/ebenen Icon/ebenen.swift
.build/icon/ebenen Icon/AppIcon.icon/Assets

echo "==> actool (Xcode for this call only)"
OUT=.build/icon/out
rm -rf "$OUT"; mkdir -p "$OUT"
DEVELOPER_DIR="$XCODE" "$XCODE/usr/bin/actool" Icon/AppIcon.icon Icon/Farben.xcassets \
  --compile "$OUT" --platform macosx --minimum-deployment-target 26.0 --target-device mac \
  --app-icon AppIcon --accent-color AccentColor --include-all-app-icons \
  --output-partial-info-plist "$OUT/partial.plist" --output-format human-readable-text --notices --warnings --errors
cp "$OUT/Assets.car" Resources/Assets.car
cp "$OUT/AppIcon.icns" Resources/AppIcon.icns
echo "==> Resources/Assets.car and Resources/AppIcon.icns updated"
cat "$OUT/partial.plist"
