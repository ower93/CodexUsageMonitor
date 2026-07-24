#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexUsageMonitor"
BUNDLE_ID="com.kevinchen.CodexUsageMonitor"
APP_VERSION="1.2.1"
BUILD_NUMBER="4"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${CODEX_USAGE_DIST_DIR:-$ROOT_DIR/dist}"
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
FINAL_APP_BINARY="$FINAL_APP_BUNDLE/Contents/MacOS/$APP_NAME"

cleanup_staging() {
  rm -rf -- "$STAGING_DIR"
}
trap cleanup_staging EXIT

pid_is_running_dist_app() {
  local pid="$1"
  local command
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == "$FINAL_APP_BINARY" ]]
}

running_dist_pids() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if pid_is_running_dist_app "$pid"; then
      echo "$pid"
    fi
  done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)
}

wait_for_dist_pid_exit() {
  local pid="$1"
  local attempt
  for attempt in {1..60}; do
    pid_is_running_dist_app "$pid" || return 0
    sleep 0.1
  done
  return 1
}

stop_running_dist_app() {
  local pid pids
  pids="$(running_dist_pids)"

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done <<<"$pids"

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if ! wait_for_dist_pid_exit "$pid"; then
      if pid_is_running_dist_app "$pid"; then
        echo "App PID $pid did not terminate in time; forcing the same verified process to exit." >&2
        kill -KILL "$pid" 2>/dev/null || true
      fi
      if ! wait_for_dist_pid_exit "$pid"; then
        echo "Unable to stop app PID $pid safely." >&2
        return 1
      fi
    fi
  done <<<"$pids"
}

capture_single_running_dist_pid() {
  local attempt count pid pids
  for attempt in {1..100}; do
    pids="$(running_dist_pids)"
    count="$(printf '%s\n' "$pids" | awk 'NF { count += 1 } END { print count + 0 }')"
    if (( count == 1 )); then
      pid="$(printf '%s\n' "$pids" | awk 'NF { print; exit }')"
      echo "$pid"
      return 0
    fi
    if (( count > 1 )); then
      echo "Expected one newly launched app, found $count matching processes." >&2
      return 1
    fi
    sleep 0.1
  done
  echo "The newly launched app did not appear in time." >&2
  return 1
}

stop_running_dist_app

cd "$ROOT_DIR"
mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm" "$BUILD_DIR"
export SDKROOT="${SDKROOT:-$SDK_PATH}"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_DIR/swiftpm"

# Release bundles must never reuse an object file from an older checkout merely
# because the source timestamps are older than the local SwiftPM cache.
"$SWIFT_BIN" package --scratch-path "$BUILD_DIR" clean

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
/usr/bin/xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/bin/ditto "$APP_BUNDLE" "$FINAL_APP_BUNDLE"
/usr/bin/xattr -cr "$FINAL_APP_BUNDLE"
/usr/bin/xattr -d com.apple.FinderInfo "$FINAL_APP_BUNDLE" 2>/dev/null || true
/usr/bin/codesign --verify --deep --strict --verbose=2 "$FINAL_APP_BUNDLE"

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
    if [[ -n "$(running_dist_pids)" ]]; then
      echo "A matching app process appeared before verification launch." >&2
      exit 1
    fi
    open_app
    if ! launched_pid="$(capture_single_running_dist_pid)"; then
      stop_running_dist_app
      exit 1
    fi
    sleep 1
    if ! pid_is_running_dist_app "$launched_pid"; then
      echo "Verified launch PID $launched_pid exited prematurely." >&2
      exit 1
    fi
    echo "Verified newly launched app PID: $launched_pid"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
