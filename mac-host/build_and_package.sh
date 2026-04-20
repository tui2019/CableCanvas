#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="CableCanvas"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"
DMG_PATH="$BUILD_DIR/${APP_NAME}.dmg"
APK_PATH="$SCRIPT_DIR/prebuilt/app.apk"
ICON_PATH="$SCRIPT_DIR/Resources/AppIcon.icns"

if [[ ! -f "$APK_PATH" ]]; then
  echo "Missing Android APK: $APK_PATH" >&2
  exit 1
fi

if [[ ! -f "$ICON_PATH" ]]; then
  echo "Missing app icon: $ICON_PATH" >&2
  exit 1
fi

echo "Building macOS binary..."
swift build -c release

BIN_PATH="$(find "$SCRIPT_DIR/.build" -type f -name CableCanvasHost | grep '/release/' | head -n1)"
if [[ -z "$BIN_PATH" ]]; then
  echo "Could not locate release binary (CableCanvasHost)." >&2
  exit 1
fi

echo "Packaging app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$APK_PATH" "$APP_DIR/Contents/Resources/app.apk"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>CableCanvas</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>com.cablecanvas.app</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>CableCanvas</string>
<key>CFBundleDisplayName</key><string>CableCanvas</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP_DIR"

echo "Creating DMG..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGING"

echo "Done:"
echo "  App: $APP_DIR"
echo "  DMG: $DMG_PATH"
