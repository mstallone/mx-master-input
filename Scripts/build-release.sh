#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPOSITORY_ROOT
readonly PROJECT_PATH="$REPOSITORY_ROOT/MXMasterInput.xcodeproj"
readonly SCHEME="MXMasterInput"
readonly PRODUCT_NAME="MXMasterInput"
readonly SOURCE_INFO_PLIST="$REPOSITORY_ROOT/Sources/MXMasterInput/Info.plist"
readonly EXPECTED_TEAM_ID="${APPLE_TEAM_ID:-8KZBNZJBAX}"
readonly RELEASE_TAG="${1:-${GITHUB_REF_NAME:-}}"
readonly SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION_IDENTITY:-}"
readonly NOTARY_KEY_PATH="${APPLE_NOTARY_KEY_PATH:-}"
readonly NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-}"
readonly NOTARY_ISSUER_ID="${APPLE_NOTARY_ISSUER_ID:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "release tag must use the form v1.2.3"

readonly RELEASE_VERSION="${RELEASE_TAG#v}"
DECLARED_VERSION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print:CFBundleShortVersionString' \
    "$SOURCE_INFO_PLIST"
)"
readonly DECLARED_VERSION

[[ "$RELEASE_VERSION" == "$DECLARED_VERSION" ]] ||
  fail "tag $RELEASE_TAG does not match app version $DECLARED_VERSION"

[[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] ||
  fail "DEVELOPER_ID_APPLICATION_IDENTITY must be a Developer ID Application identity"
[[ "$SIGNING_IDENTITY" == *"($EXPECTED_TEAM_ID)" ]] ||
  fail "signing identity does not belong to NextByte team $EXPECTED_TEAM_ID"
[[ -n "$NOTARY_KEY_PATH" && -f "$NOTARY_KEY_PATH" ]] ||
  fail "APPLE_NOTARY_KEY_PATH must point to an App Store Connect API private key"
[[ -n "$NOTARY_KEY_ID" ]] || fail "APPLE_NOTARY_KEY_ID is required"
[[ -n "$NOTARY_ISSUER_ID" ]] || fail "APPLE_NOTARY_ISSUER_ID is required"

require_command codesign
require_command ditto
require_command lipo
require_command plutil
require_command shasum
require_command spctl
require_command syspolicy_check
require_command xcodebuild
require_command xcrun

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mx-master-input-release.XXXXXX")"
readonly BUILD_ROOT
readonly ARCHIVE_PATH="$BUILD_ROOT/$PRODUCT_NAME.xcarchive"
readonly APP_PATH="$ARCHIVE_PATH/Products/Applications/$PRODUCT_NAME.app"
readonly NOTARY_ARCHIVE="$BUILD_ROOT/notarization.zip"
readonly NOTARY_RESULT="$BUILD_ROOT/notary-result.json"
readonly OUTPUT_DIRECTORY="${RELEASE_OUTPUT_DIR:-$REPOSITORY_ROOT/dist}"
readonly RELEASE_ARCHIVE="$OUTPUT_DIRECTORY/$PRODUCT_NAME-$RELEASE_VERSION-macOS.zip"
readonly RELEASE_CHECKSUM="$RELEASE_ARCHIVE.sha256"

cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT

build_settings=(
  "ARCHS=arm64 x86_64"
  "ONLY_ACTIVE_ARCH=NO"
  "CODE_SIGN_STYLE=Manual"
  "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
  "DEVELOPMENT_TEAM=$EXPECTED_TEAM_ID"
  "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"
  "ENABLE_HARDENED_RUNTIME=YES"
  "OTHER_CODE_SIGN_FLAGS=--timestamp"
)

if [[ -n "${RELEASE_KEYCHAIN_PATH:-}" ]]; then
  build_settings+=(
    "OTHER_CODE_SIGN_FLAGS=--timestamp --keychain ${RELEASE_KEYCHAIN_PATH}"
  )
fi

printf 'Archiving %s %s for arm64 and x86_64...\n' "$PRODUCT_NAME" "$RELEASE_VERSION"
/usr/bin/xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_ROOT/DerivedData" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  "${build_settings[@]}" \
  archive

[[ -d "$APP_PATH" ]] || fail "archive did not contain $PRODUCT_NAME.app"

readonly EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
ARCHITECTURES="$(/usr/bin/lipo -archs "$EXECUTABLE_PATH")"
readonly ARCHITECTURES
[[ " $ARCHITECTURES " == *" arm64 "* ]] ||
  fail "release executable is missing arm64"
[[ " $ARCHITECTURES " == *" x86_64 "* ]] ||
  fail "release executable is missing x86_64"

if /usr/bin/find "$APP_PATH" -name '*.debug.dylib' -print -quit | /usr/bin/grep -q .; then
  fail "release contains a debug dylib"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNATURE_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$APP_PATH" 2>&1)"
readonly SIGNATURE_DETAILS

/usr/bin/grep -Fq 'Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS" ||
  fail "release is not signed with Developer ID Application"
/usr/bin/grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$SIGNATURE_DETAILS" ||
  fail "release signature has the wrong team identifier"
/usr/bin/grep -Eq 'flags=.*runtime' <<<"$SIGNATURE_DETAILS" ||
  fail "release signature does not enable hardened runtime"
/usr/bin/grep -Fq 'Timestamp=' <<<"$SIGNATURE_DETAILS" ||
  fail "release signature does not include a secure timestamp"

ENTITLEMENTS="$(
  /usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>&1 || true
)"
readonly ENTITLEMENTS
if /usr/bin/grep -Fq 'com.apple.security.get-task-allow' <<<"$ENTITLEMENTS"; then
  fail "release contains the development get-task-allow entitlement"
fi

printf 'Submitting the signed app to Apple notarization...\n'
/usr/bin/ditto \
  -c -k --keepParent --sequesterRsrc \
  "$APP_PATH" \
  "$NOTARY_ARCHIVE"

/usr/bin/xcrun notarytool submit "$NOTARY_ARCHIVE" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait \
  --timeout 45m \
  --output-format json >"$NOTARY_RESULT"

NOTARY_STATUS="$(
  /usr/bin/plutil -extract status raw -o - -- "$NOTARY_RESULT"
)"
readonly NOTARY_STATUS
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  /bin/cat "$NOTARY_RESULT" >&2
  fail "Apple notarization returned $NOTARY_STATUS"
fi

printf 'Stapling and validating the notarization ticket...\n'
/usr/bin/xcrun stapler staple -v "$APP_PATH"
/usr/bin/xcrun stapler validate -v "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

printf 'Running Gatekeeper and macOS distribution assessments...\n'
if ! GATEKEEPER_RESULT="$(
  /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1
)"; then
  printf '%s\n' "$GATEKEEPER_RESULT" >&2
  fail "Gatekeeper rejected the release"
fi
printf '%s\n' "$GATEKEEPER_RESULT"
/usr/bin/grep -Fq 'source=Notarized Developer ID' <<<"$GATEKEEPER_RESULT" ||
  fail "Gatekeeper did not identify the release as Notarized Developer ID"

/usr/bin/syspolicy_check distribution "$APP_PATH" --verbose

/bin/mkdir -p "$OUTPUT_DIRECTORY"
/bin/rm -f "$RELEASE_ARCHIVE" "$RELEASE_CHECKSUM"
/usr/bin/ditto \
  -c -k --keepParent --sequesterRsrc \
  "$APP_PATH" \
  "$RELEASE_ARCHIVE"

(
  cd "$OUTPUT_DIRECTORY"
  /usr/bin/shasum -a 256 "$(basename "$RELEASE_ARCHIVE")" \
    >"$(basename "$RELEASE_CHECKSUM")"
)

printf 'Release artifacts:\n%s\n%s\n' "$RELEASE_ARCHIVE" "$RELEASE_CHECKSUM"
