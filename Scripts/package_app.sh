#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/CodexMonitorMinibar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"
swift build -c release --disable-sandbox --product CodexMonitorMinibar
swift build -c release --disable-sandbox --product CodexMonitorHookBridge

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/CodexMonitorMinibar" "$MACOS_DIR/CodexMonitorMinibar"
cp "$ROOT_DIR/.build/release/CodexMonitorHookBridge" "$MACOS_DIR/CodexMonitorHookBridge"
rm -rf "$RESOURCES_DIR/CodexMonitorMinibar.iconset"
swift "$ROOT_DIR/Scripts/generate_app_icon.swift" "$RESOURCES_DIR/CodexMonitorMinibar.icns"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>CodexMonitorMinibar</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.aaronoho.CodexMonitorMinibar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>CodexMonitorMinibar</string>
  <key>CFBundleName</key>
  <string>CodexMonitorMinibar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.5</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
