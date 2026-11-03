#!/usr/bin/env bash
# Read-only checks. Does not sign, upload, notarize, install, or change settings.
set -euo pipefail
APP="${1:?usage: bash script/release_preflight.sh /path/to/CodexUsageMonitor.app}"
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || { echo "FAIL: missing Info.plist" >&2; exit 1; }
failures=0
check() {
  local label="$1"
  shift
  if "$@"; then
    echo "PASS: $label"
  else
    echo "FAIL: $label" >&2
    failures=$((failures + 1))
  fi
}
check "bundle signatures" /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
check "third-party notice" test -s "$APP/Contents/Resources/ThirdPartyLicenses/THIRD_PARTY_NOTICES.md"
check "Sparkle license" test -s "$APP/Contents/Resources/ThirdPartyLicenses/Sparkle-2.10.0.txt"
DETAILS="$(/usr/bin/codesign -dvvv "$APP" 2>&1 || true)"
if [[ "$DETAILS" == *"Authority=Developer ID Application:"* && "$DETAILS" == *"runtime"* ]]; then
  echo "PASS: Developer ID and hardened runtime"
else
  echo "FAIL: public distribution requires Developer ID and hardened runtime" >&2
  failures=$((failures + 1))
fi
EXECUTABLE="$(/usr/bin/plutil -extract CFBundleExecutable raw "$PLIST")"
/usr/bin/file "$APP/Contents/MacOS/$EXECUTABLE"
/usr/bin/plutil -extract CFBundleShortVersionString raw "$PLIST"
/usr/bin/plutil -extract CFBundleVersion raw "$PLIST"
check "stapled notarization ticket" /usr/bin/xcrun stapler validate "$APP"
check "Gatekeeper assessment" /usr/sbin/spctl --assess --type execute --verbose=4 "$APP"
FEED="$(/usr/bin/plutil -extract SUFeedURL raw "$PLIST" 2>/dev/null || true)"
KEY="$(/usr/bin/plutil -extract SUPublicEDKey raw "$PLIST" 2>/dev/null || true)"
if [[ "$FEED" == https://* && -n "$KEY" ]] && \
   [[ "$(/usr/bin/plutil -extract SUVerifyUpdateBeforeExtraction raw "$PLIST" 2>/dev/null || true)" == true ]] && \
   [[ "$(/usr/bin/plutil -extract SURequireSignedFeed raw "$PLIST" 2>/dev/null || true)" == true ]]; then
  echo "PASS: signed-update configuration present (old-to-new test still required)"
else
  echo "FAIL: Sparkle feed/key/signature policy not configured" >&2
  failures=$((failures + 1))
fi
[[ "$failures" -eq 0 ]] || { echo "$failures release gate(s) remain." >&2; exit 1; }
echo "Static release checks passed. A clean-machine install and signed update test are still required."
