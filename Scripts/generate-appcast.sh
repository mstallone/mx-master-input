#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPOSITORY_ROOT
readonly PRODUCT_NAME="MXMasterInput"
readonly RELEASE_TAG="${1:-${GITHUB_REF_NAME:-}}"
readonly GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST_PATH:-}"
readonly PRIVATE_KEY="${SPARKLE_ED_PRIVATE_KEY:-}"
readonly OUTPUT_DIRECTORY="${RELEASE_OUTPUT_DIR:-$REPOSITORY_ROOT/dist}"
readonly REPOSITORY="${GITHUB_REPOSITORY:-mstallone/mx-master-input}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "release tag must use the form v1.2.3"
[[ -x "$GENERATE_APPCAST" ]] ||
  fail "SPARKLE_GENERATE_APPCAST_PATH must point to Sparkle's generate_appcast tool"
[[ -n "$PRIVATE_KEY" ]] ||
  fail "SPARKLE_ED_PRIVATE_KEY is required"

readonly RELEASE_VERSION="${RELEASE_TAG#v}"
readonly RELEASE_ARCHIVE="$OUTPUT_DIRECTORY/$PRODUCT_NAME-$RELEASE_VERSION-macOS.zip"
readonly APPCAST="$OUTPUT_DIRECTORY/appcast.xml"
readonly RELEASE_URL="https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"
readonly DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/"

[[ -f "$RELEASE_ARCHIVE" ]] ||
  fail "release archive not found: $RELEASE_ARCHIVE"

printf '%s' "$PRIVATE_KEY" |
  "$GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --link "$RELEASE_URL" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    --disable-signing-warning \
    -o "$APPCAST" \
    "$OUTPUT_DIRECTORY"

/usr/bin/xmllint --noout "$APPCAST"
/usr/bin/grep -Fq "<sparkle:version>$RELEASE_VERSION</sparkle:version>" "$APPCAST" ||
  fail "appcast does not contain release version $RELEASE_VERSION"
/usr/bin/grep -Fq \
  "<sparkle:shortVersionString>$RELEASE_VERSION</sparkle:shortVersionString>" \
  "$APPCAST" ||
  fail "appcast does not contain short release version $RELEASE_VERSION"
/usr/bin/grep -Fq "sparkle:edSignature=" "$APPCAST" ||
  fail "appcast release archive is not signed"
/usr/bin/grep -Fq "$DOWNLOAD_PREFIX$(basename "$RELEASE_ARCHIVE")" "$APPCAST" ||
  fail "appcast download URL is incorrect"

printf 'Sparkle appcast: %s\n' "$APPCAST"
