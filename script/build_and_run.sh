#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexUsageMonitor"
BUNDLE_ID="com.kevinchen.CodexUsageMonitor"
APP_VERSION="1.2"
BUILD_NUMBER="2"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFT_BIN="$(/usr/bin/xcrun --find swift)"
CACHE_DIR="$ROOT_DIR/work/xcode-build-cache"
BUILD_DIR="${CODEX_USAGE_BUILD_DIR:-$CACHE_DIR/build}"
BUILD_JOBS="${SWIFT_BUILD_JOBS:-1}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/CodexUsageMonitor.XXXXXX")"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
FINAL_APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.icns"

trap 'rm -rf "$STAGING_DIR"' EXIT

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm" "$BUILD_DIR"
export SDKROOT="${SDKROOT:-$SDK_PATH}"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_DIR/swiftpm"

"$SWIFT_BIN" build \
  --disable-sandbox \
  --jobs "$BUILD_JOBS" \
  --scratch-path "$BUILD_DIR" \
  --product "$APP_NAME"
BUILD_BINARY="$("$SWIFT_BIN" build --disable-sandbox --scratch-path "$BUILD_DIR" --show-bin-path)/$APP_NAME"

mkdir -p "$APP_MACOS" "$APP_RESOURCES"
install -m 755 "$BUILD_BINARY" "$APP_BINARY"
install -m 644 "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Codex 用量</string>
  <key>CFBundleDisplayName</key>
  <string>Codex Usage Monitor</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/xattr -cr "$APP_BUNDLE"
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
/usr/bin/ditto "$APP_BUNDLE" "$FINAL_APP_BUNDLE"
/usr/bin/codesign --verify --deep "$FINAL_APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$FINAL_APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
