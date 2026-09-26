#!/bin/bash
# Builds a universal, Developer ID-signed, hardened, notarized, stapled MXMasterInput.app and zips it.
# Runs in CI (release.yml). The tag is the version: v1.2.3 -> 1.2.3.
#
# Required env (release.yml provides them):
#   DEVELOPER_ID_APPLICATION_IDENTITY   "Developer ID Application: NextByte, Inc. (8KZBNZJBAX)"
#   APPLE_NOTARY_KEY_PATH / APPLE_NOTARY_KEY_ID / APPLE_NOTARY_ISSUER_ID   App Store Connect API key
# Optional: RELEASE_KEYCHAIN_PATH (CI's temporary keychain), APPLE_TEAM_ID, RELEASE_OUTPUT_DIR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PRODUCT="MXMasterInput"
readonly EXPECTED_TEAM_ID="${APPLE_TEAM_ID:-8KZBNZJBAX}"
readonly RELEASE_TAG="${1:-${GITHUB_REF_NAME:-}}"
readonly SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION_IDENTITY:-}"
readonly NOTARY_KEY_PATH="${APPLE_NOTARY_KEY_PATH:-}"
readonly NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-}"
readonly NOTARY_ISSUER_ID="${APPLE_NOTARY_ISSUER_ID:-}"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "release tag must use the form v1.2.3"
readonly VERSION="${RELEASE_TAG#v}"
[[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] || fail "DEVELOPER_ID_APPLICATION_IDENTITY must be a Developer ID Application identity"
[[ "$SIGNING_IDENTITY" == *"($EXPECTED_TEAM_ID)" ]] || fail "signing identity does not belong to NextByte team $EXPECTED_TEAM_ID"
[[ -f "$NOTARY_KEY_PATH" ]] || fail "APPLE_NOTARY_KEY_PATH must point to an App Store Connect API private key"
[[ -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER_ID" ]] || fail "APPLE_NOTARY_KEY_ID and APPLE_NOTARY_ISSUER_ID are required"
for tool in codesign ditto lipo plutil shasum spctl syspolicy_check xcrun; do
  command -v "$tool" >/dev/null || fail "required command not found: $tool"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mx-master-input-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
readonly APP="$WORK/$PRODUCT.app"
readonly OUT="${RELEASE_OUTPUT_DIR:-$ROOT/dist}"
readonly ARCHIVE="$OUT/$PRODUCT-$VERSION-macOS.zip"

printf 'Building %s %s for arm64 and x86_64...\n' "$PRODUCT" "$VERSION"
cd "$ROOT"
swift build -c release --arch arm64 --arch x86_64
"$SCRIPT_DIR/build-app.sh" "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$PRODUCT" "$APP" "$VERSION"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/$PRODUCT")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]] || fail "expected a universal binary, got: $ARCHS"

printf 'Signing with Developer ID (hardened runtime, secure timestamp)...\n'
flags=(--options runtime --timestamp)
[[ -n "${RELEASE_KEYCHAIN_PATH:-}" ]] && flags+=(--keychain "$RELEASE_KEYCHAIN_PATH")
"$SCRIPT_DIR/sign.sh" "$APP" "$SIGNING_IDENTITY" "${flags[@]}"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for code in "$APP" "$SPARKLE" "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" \
            "$SPARKLE/Versions/B/XPCServices/Installer.xpc" "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"; do
  DETAILS="$(codesign -d --verbose=4 "$code" 2>&1)"
  grep -Fq 'Authority=Developer ID Application:' <<<"$DETAILS" || fail "$code is not signed with Developer ID Application"
  grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$DETAILS" || fail "$code has the wrong team identifier"
  grep -Eq 'flags=.*runtime' <<<"$DETAILS" || fail "$code does not enable hardened runtime"
  grep -Fq 'Timestamp=' <<<"$DETAILS" || fail "$code does not include a secure timestamp"
done
if codesign -d --entitlements :- "$APP" 2>&1 | grep -Fq 'com.apple.security.get-task-allow'; then
  fail "release contains the development get-task-allow entitlement"
fi

printf 'Submitting to Apple notarization...\n'
ditto -c -k --keepParent --sequesterRsrc "$APP" "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" \
  --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
  --wait --timeout 45m --output-format json >"$WORK/notary.json"
STATUS="$(plutil -extract status raw -o - -- "$WORK/notary.json")"
if [[ "$STATUS" != "Accepted" ]]; then
  cat "$WORK/notary.json" >&2
  xcrun notarytool log "$(plutil -extract id raw -o - -- "$WORK/notary.json")" \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" >&2 || true
  fail "Apple notarization returned $STATUS"
fi

printf 'Stapling and validating...\n'
xcrun stapler staple -v "$APP"
xcrun stapler validate -v "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
GATEKEEPER="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1)" || { printf '%s\n' "$GATEKEEPER" >&2; fail "Gatekeeper rejected the release"; }
grep -Fq 'source=Notarized Developer ID' <<<"$GATEKEEPER" || fail "Gatekeeper did not identify the release as Notarized Developer ID"
syspolicy_check distribution "$APP" --verbose

mkdir -p "$OUT"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ARCHIVE"
(cd "$OUT" && shasum -a 256 "$(basename "$ARCHIVE")" >"$(basename "$ARCHIVE").sha256")
printf 'Release artifacts:\n%s\n%s.sha256\n' "$ARCHIVE" "$ARCHIVE"
