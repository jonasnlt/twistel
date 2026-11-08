#!/usr/bin/env bash
# Builds the app with swiftc alone (Command Line Tools) and the macOS 26.5 SDK, without Brisk.
# Result: ".build/debug/twistel dev.app" (with --release: .build/release/twistel.app)
# Name and bundle ID must match Sources/Core/AppIdentity.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

# Swift module: always "Twistel" (a module name can't contain a space); the app, its executable and the menu bar use APP_NAME.
MODULE_NAME="Twistel"
# Version 1.0.0; the build number goes up with every build of the same version that is passed on.
VERSION="1.0.0"
BUILD_NUMBER="1"
DEPLOYMENT_TARGET="26.0"

CONFIG="debug"
# Debug builds get DEBUG: only they contain the test access (--run-tool, Sources/App/ToolDriver.swift). They are called "twistel dev"
# and have a bundle ID of their own, so they never share settings, keychain items or services with the real app.
APP_NAME="twistel dev"
BUNDLE_ID="io.github.jonasnlt.twistel.debug"
OPT_FLAGS=(-Onone -g -D DEBUG)
if [[ "${1:-}" == "--release" ]]; then
  CONFIG="release"
  APP_NAME="twistel"
  BUNDLE_ID="io.github.jonasnlt.twistel"
  OPT_FLAGS=(-O)
fi

export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$SDKROOT" ]]; then
  echo "SDK not found: $SDKROOT" >&2
  exit 1
fi

FRAMEWORKS=(AppKit AVFoundation AVKit Combine CoreImage SwiftUI CoreMedia CoreText ImageIO PDFKit Quartz
  UniformTypeIdentifiers ServiceManagement Accelerate Vision QuickLookThumbnailing AudioToolbox CoreAudio)
FRAMEWORK_FLAGS=()
for f in "${FRAMEWORKS[@]}"; do FRAMEWORK_FLAGS+=(-framework "$f"); done

OUT=".build/$CONFIG"
APP="$OUT/$APP_NAME.app"
TMP="$OUT/tmp"
rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"

# Collect all source files (safe with spaces)
SOURCES=()
while IFS= read -r -d '' f; do SOURCES+=("$f"); done < <(find Sources -name '*.swift' -print0 | sort -z)

echo "==> Compiling (${#SOURCES[@]} files, $CONFIG)"
swiftc \
  -sdk "$SDKROOT" \
  -target "arm64-apple-macosx$DEPLOYMENT_TARGET" \
  -swift-version 5 \
  -parse-as-library \
  "${OPT_FLAGS[@]}" \
  "${FRAMEWORK_FLAGS[@]}" \
  -module-name "$MODULE_NAME" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "${SOURCES[@]}"

echo "==> App icon"
# The icon and the accent color are prebuilt in Resources/ (Assets.car for macOS 26 with dark, tinted and clear looks, AppIcon.icns as a
# fallback). scripts/icon.sh makes them from Icon/AppIcon.icon; that needs Xcode, this build does not.
[[ -f Resources/Assets.car && -f Resources/AppIcon.icns ]] || { echo "Resources/Assets.car or AppIcon.icns is missing: run scripts/icon.sh" >&2; exit 1; }

# Other resources (except placeholders); language folders (de.lproj) stay folders.
(cd Resources && find . -type f ! -name '.gitkeep' -print0 | while IFS= read -r -d '' f; do
  mkdir -p "../$APP/Contents/Resources/$(dirname "$f")"; cp "$f" "../$APP/Contents/Resources/$f"; done)

# Licenses into the app (the GPL-3.0 asks for the license text to go with the program): twistel and Satsuma (MIT).
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
mkdir -p "$APP/Contents/Resources/LICENSES"
cp LICENSES/* "$APP/Contents/Resources/LICENSES/"

# For twistel dev: "twistel dev" in the German service names too, and the icon with a small "DEV" label.
ICON_KEYS="<key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>"
if [[ "$CONFIG" == "debug" ]]; then
  sed -i '' "s/twistel/$APP_NAME/g" "$APP/Contents/Resources/de.lproj/ServicesMenu.strings"
  DEV_ICON=".build/dev-icon/AppIcon-Dev.icns"
  if [[ ! -f "$DEV_ICON" || Resources/AppIcon.icns -nt "$DEV_ICON" || scripts/dev-icon.swift -nt "$DEV_ICON" ]]; then
    rm -rf .build/dev-icon && mkdir -p .build/dev-icon
    swift scripts/dev-icon.swift Resources/AppIcon.icns .build/dev-icon/AppIcon-Dev.iconset
    iconutil -c icns .build/dev-icon/AppIcon-Dev.iconset -o "$DEV_ICON"
  fi
  cp "$DEV_ICON" "$APP/Contents/Resources/AppIcon-Dev.icns"
  # Without CFBundleIconName macOS takes the .icns instead of the icon in Assets.car.
  ICON_KEYS="<key>CFBundleIconFile</key><string>AppIcon-Dev</string>"
fi

# Finder: right-click on files › Services. Only twistel offers them; twistel dev does not (otherwise the menu shows six entries).
# To try the services in a debug build: TWISTEL_DEV_SERVICES=1 ./scripts/build.sh
SERVICES=""
if [[ "$CONFIG" == "release" || "${TWISTEL_DEV_SERVICES:-}" == "1" ]]; then
  SERVICES=$(cat <<SERVICESXML
  <!-- Finder: right-click on files › Services/Quick Actions. macOS reads this once it knows the app. -->
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Convert with $APP_NAME</string></dict>
      <key>NSMessage</key><string>convertFiles</string>
      <key>NSPortName</key><string>$APP_NAME</string>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Tools in $APP_NAME</string></dict>
      <key>NSMessage</key><string>toolFiles</string>
      <key>NSPortName</key><string>$APP_NAME</string>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Actions in $APP_NAME</string></dict>
      <key>NSMessage</key><string>actionFiles</string>
      <key>NSPortName</key><string>$APP_NAME</string>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
      <key>NSRequiredContext</key><dict/>
    </dict>
  </array>
SERVICESXML
)
fi

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  $ICON_KEYS
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 jonasnlt</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
$SERVICES
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (ad hoc)"
if [[ "$CONFIG" == "release" ]]; then
  # Hardened Runtime: macOS loads no foreign libraries into the app (DYLD_INSERT_LIBRARIES and the like have no effect) and lets no
  # debugger attach. No entitlements: the app needs no exception from it (no JIT, no foreign libraries, no Apple Events, no
  # microphone, no camera).
  codesign --force --options runtime --sign - "$APP"
else
  codesign --force --sign - "$APP"
fi

rm -rf "$TMP"
echo "Done: $APP"
