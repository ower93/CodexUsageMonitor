#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexUsageMonitor"
BUNDLE_ID="${CODEX_USAGE_BUNDLE_ID:-com.kevinchen.CodexUsageMonitor}"
APP_VERSION="2.0.1"
BUILD_NUMBER="10"
CONFIGURATION="${CODEX_USAGE_CONFIGURATION:-release}"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${CODEX_USAGE_DIST_DIR:-$ROOT_DIR/dist}"
SDK_PATH="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
SWIFT_BIN="$(/usr/bin/xcrun --find swift)"
CACHE_DIR="${CODEX_USAGE_CACHE_DIR:-${TMPDIR:-/tmp}/CodexUsageMonitor-package-cache}"
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
DESTINATION_STAGING=""

cleanup_staging() {
  rm -rf -- "$STAGING_DIR"
  if [[ -n "$DESTINATION_STAGING" && ! -e "$DESTINATION_STAGING/previous.app" ]]; then
    rm -rf -- "$DESTINATION_STAGING"
  fi
}
trap cleanup_staging EXIT

pid_is_running_dist_app() {
  local pid="$1"
  local command physical_binary physical_directory command_prefix command_directory
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  physical_directory="$(cd "$FINAL_APP_BUNDLE/Contents/MacOS" 2>/dev/null && pwd -P || true)"
  physical_binary=""
  [[ -z "$physical_directory" ]] || physical_binary="$physical_directory/$APP_NAME"
  if [[ "$command" == "$FINAL_APP_BINARY" || "$command" == "$FINAL_APP_BINARY "* \
      || ( -n "$physical_binary" && ( "$command" == "$physical_binary" || "$command" == "$physical_binary "* ) ) ]]; then
    return 0
  fi
  command_prefix="${command%%.app/Contents/MacOS/$APP_NAME*}"
  [[ "$command_prefix" != "$command" && -n "$physical_directory" ]] || return 1
  command_directory="$(cd "$command_prefix.app/Contents/MacOS" 2>/dev/null && pwd -P || true)"
  [[ "$command_directory" == "$physical_directory" ]]
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
        echo "App PID $pid did not terminate cleanly; leaving the existing bundle intact." >&2
        return 1
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

case "$MODE" in
  --package|package)
    if [[ -n "$(running_dist_pids)" ]]; then
      echo "Quit the app at $FINAL_APP_BUNDLE before replacing its bundle." >&2; exit 1
    fi
    ;;
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) stop_running_dist_app ;;
  *) echo "usage: $0 [--package|run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm" "$BUILD_DIR"
export SDKROOT="${SDKROOT:-$SDK_PATH}"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_DIR/swiftpm"

# Release bundles must never reuse an object file from an older checkout merely
# because the source timestamps are older than the local SwiftPM cache.
if [[ "${CLEAN_BUILD:-1}" == "1" ]]; then
  "$SWIFT_BIN" package --scratch-path "$BUILD_DIR" clean
fi

"$SWIFT_BIN" build \
  --disable-sandbox \
  --sdk "$SDK_PATH" \
  --jobs "$BUILD_JOBS" \
  --scratch-path "$BUILD_DIR" \
  --configuration "$CONFIGURATION" \
  --product "$APP_NAME"
BIN_DIR="$("$SWIFT_BIN" build --disable-sandbox --sdk "$SDK_PATH" --scratch-path "$BUILD_DIR" --configuration "$CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BIN_DIR/$APP_NAME"

mkdir -p "$APP_MACOS" "$APP_RESOURCES"
install -m 755 "$BUILD_BINARY" "$APP_BINARY"
install -m 644 "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
mkdir -p "$APP_RESOURCES/ThirdPartyLicenses"
install -m 644 "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_RESOURCES/ThirdPartyLicenses/THIRD_PARTY_NOTICES.md"
install -m 644 "$ROOT_DIR/Assets/ThirdPartyLicenses/Sparkle-2.10.0.txt" "$APP_RESOURCES/ThirdPartyLicenses/Sparkle-2.10.0.txt"
# SwiftPM's generated Bundle.module accessor expects the named resource bundle
# inside Contents/Resources when distributed outside the build directory.
for resource in "$BIN_DIR"/*.bundle; do
  [[ -d "$resource" ]] || continue
  /usr/bin/ditto "$resource" "$APP_RESOURCES/$(basename "$resource")"
done
if [[ ! -d "$BIN_DIR/Sparkle.framework" ]]; then
  echo "Sparkle.framework was not produced; refusing an incomplete app bundle." >&2
  exit 1
fi
mkdir -p "$APP_CONTENTS/Frameworks"
/usr/bin/ditto "$BIN_DIR/Sparkle.framework" "$APP_CONTENTS/Frameworks/Sparkle.framework"

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
  <key>SUEnableAutomaticChecks</key>
  <false/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>SURequireSignedFeed</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -n "${SPARKLE_FEED_URL:-}" || -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  [[ "${SPARKLE_FEED_URL:-}" == https://* && -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] || {
    echo "Both an HTTPS feed and its public Ed25519 key are required." >&2; exit 1;
  }
  /usr/bin/plutil -insert SUFeedURL -string "$SPARKLE_FEED_URL" "$INFO_PLIST"
  /usr/bin/plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$INFO_PLIST"
fi
if [[ -n "${PRICING_PUBLIC_ED_KEY:-}" ]]; then
  /usr/bin/plutil -insert CUMCatalogPublicKey -string "$PRICING_PUBLIC_ED_KEY" "$INFO_PLIST"
fi

/usr/bin/xattr -cr "$APP_BUNDLE"
/usr/bin/xattr -d com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
# Sign nested code from the inside out. Never use --deep to sign a release.
SIGN_OPTIONS=(--force --options 0 --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGN_OPTIONS=(--force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
fi
FRAMEWORK="$APP_CONTENTS/Frameworks/Sparkle.framework"
for nested in "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
              "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
              "$FRAMEWORK/Versions/B/Autoupdate" \
              "$FRAMEWORK/Versions/B/Updater.app"; do
  [[ -e "$nested" ]] || continue
  /usr/bin/codesign "${SIGN_OPTIONS[@]}" "$nested"
done
/usr/bin/codesign "${SIGN_OPTIONS[@]}" "$FRAMEWORK"
/usr/bin/codesign "${SIGN_OPTIONS[@]}" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
mkdir -p "$DIST_DIR"
[[ ! -L "$FINAL_APP_BUNDLE" ]] || { echo "Refusing to replace a symlinked app bundle." >&2; exit 1; }
DESTINATION_STAGING="$(mktemp -d "$DIST_DIR/.CodexUsageMonitor.XXXXXX")"
/usr/bin/ditto "$APP_BUNDLE" "$DESTINATION_STAGING/$APP_NAME.app"
/usr/bin/codesign --verify --deep --strict "$DESTINATION_STAGING/$APP_NAME.app"
# Replace a whole bundle, never merge into it: removed resources must not
# survive a rebuild. Refuse an app that was launched during the build.
if [[ -n "$(running_dist_pids)" ]]; then
  echo "App launched during packaging; existing bundle was not replaced." >&2; exit 1
fi
if [[ -e "$FINAL_APP_BUNDLE" ]]; then
  mv "$FINAL_APP_BUNDLE" "$DESTINATION_STAGING/previous.app"
fi
if ! mv "$DESTINATION_STAGING/$APP_NAME.app" "$FINAL_APP_BUNDLE"; then
  [[ ! -e "$DESTINATION_STAGING/previous.app" ]] || mv "$DESTINATION_STAGING/previous.app" "$FINAL_APP_BUNDLE"
  exit 1
fi
/usr/bin/xattr -cr "$FINAL_APP_BUNDLE"
/usr/bin/xattr -d com.apple.FinderInfo "$FINAL_APP_BUNDLE" 2>/dev/null || true
/usr/bin/codesign --verify --deep --strict --verbose=2 "$FINAL_APP_BUNDLE"
rm -rf -- "$DESTINATION_STAGING/previous.app"
echo "Packaged $APP_VERSION ($BUILD_NUMBER), $CONFIGURATION: $FINAL_APP_BUNDLE"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "LOCAL BUILD ONLY: ad-hoc signed, not notarized; not a public release."
fi

open_app() {
  /usr/bin/open -n "$FINAL_APP_BUNDLE"
}

case "$MODE" in
  --package|package)
    ;;
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
