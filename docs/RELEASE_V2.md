# 2.0 release procedure / 发布验收

Status 2026-11-03: **locally installed development build**, version 2.0.1, build 10.
Source publication is separate from binary distribution. The local app is ad-hoc
signed; no new public binary release or notarization is claimed.
Local acceptance and the owner's deferred hardware checks are tracked in
`V2_IMPLEMENTATION.md`; distribution prerequisites below are not local-install gates.

## Owner-provided prerequisites

- Valid **Developer ID Application** identity in Keychain.
- Existing `notarytool` Keychain profile for the matching Apple team.
- Controlled HTTPS Sparkle appcast URL and Ed25519 public key. Keep the private
  signing key in the maintainer's Keychain, never in source control.
- Optional separate Ed25519 public key for pricing-catalog imports.

The development machine reported zero valid signing identities. Provide only
identity/profile names and public configuration; never paste private keys/passwords.

## 1. Test and package — no upload

```bash
xcrun swift test --scratch-path /tmp/CodexUsageMonitor-build --jobs 2
CODE_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
SPARKLE_FEED_URL='https://YOUR-DOMAIN/path/appcast.xml' \
SPARKLE_PUBLIC_ED_KEY='YOUR-BASE64-PUBLIC-KEY' \
bash script/build_and_run.sh --package
```

Nested Sparkle helpers/framework are signed before the main app. Developer ID
builds use hardened runtime and secure timestamps; signatures are verified.
Do not use `codesign --deep` for signing.
The app also includes `THIRD_PARTY_NOTICES.md` and the unchanged pinned Sparkle
license under `Contents/Resources/ThirdPartyLicenses/`; preflight checks both.

Ad-hoc local builds omit hardened runtime because mixed-team Sparkle code can
fail library validation. This is **not** a reason to weaken a Developer ID
build or disable system security.

The default build targets the host architecture. The validated candidate is
arm64. Intel/universal claims require a separate build and hardware validation.

## 2. Notarize only after explicit release authorization

After checking the intended bundle and identity:

```bash
ditto -c -k --keepParent dist/CodexUsageMonitor.app /tmp/CodexUsageMonitor-notary.zip
xcrun notarytool submit /tmp/CodexUsageMonitor-notary.zip \
  --keychain-profile 'YOUR-EXISTING-PROFILE' --wait
```

**Require Accepted.** An upload ID or timeout is not success. On rejection,
inspect the notary log before continuing. Then:

```bash
xcrun stapler staple dist/CodexUsageMonitor.app
bash script/release_preflight.sh dist/CodexUsageMonitor.app
```

Preflight is read-only: signatures, Developer ID/runtime, staple, Gatekeeper,
and update configuration. It correctly fails on the ad-hoc candidate.
Do not remove quarantine or disable Gatekeeper as a substitute for testing the
downloaded artifact.

## 3. Signed update acceptance

1. Archive the **stapled** app. Use the pinned Sparkle 2.10.0 tools
   (`generate_appcast`/`sign_update`) with the maintainer's Keychain.
2. Require archive signatures, signed appcast, and pre-extraction verification.
   The bundle sets `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`.
3. Stage feed/archive at the controlled HTTPS endpoint only with explicit owner
   authorization. Embedding Sparkle does not authorize publication.
4. Install an older test build with the intended production identifier, feed/key,
   and lower `CFBundleVersion`. Perform **Check for Updates**.
5. Verify download, validation, replacement, relaunch, version/build, one app/helper,
   and unchanged frozen ledger prices/amounts.
6. Tampered archives/feeds must be rejected; offline/failure must leave the old
   app usable. No developer-only path or credential may ship.

The current candidate has no maintainer feed/key; updates are disabled.
Integration is not proof that this end-to-end test passed.
The existing 1.2.4 release did not include this Sparkle integration, so its first
upgrade to 2.0 is a manual installation. Test the updater using a deliberately
lower-numbered, signed test build that already contains the same feed/key.

## 4. Clean-machine checklist

- Download the actual staged artifact in a browser; launch with normal macOS
  security protections. Test macOS 14 compatibility separately.
- Without Codex/login: honest unavailable state, no demo fallback.
- With Codex/login: read that user's account and local logs.
- Language/privacy/cards persist across relaunch; exports open correctly.
- Sleep/wake, low-power, offline/recovery, keyboard and small-screen interaction.
- Normal long-duration resource run, separating cold indexing from steady state.
- Quit leaves no helper. Backup a test ledger before migration; compare frozen
  records before/after install/update.

Only after these gates and explicit publication approval create a GitHub release
with version/build/architecture, checksum, release notes, privacy and limitations.

References: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[Sparkle publishing](https://sparkle-project.org/documentation/publishing/),
[Sparkle programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/).
