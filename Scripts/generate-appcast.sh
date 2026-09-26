#!/bin/bash
# Writes a Sparkle appcast for the release zip that build-release.sh produced, signed with the EdDSA key.
# Runs in CI (release.yml) after build-release.sh.
#   SPARKLE_ED_PRIVATE_KEY=... Scripts/generate-appcast.sh v1.2.3
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly RELEASE_TAG="${1:-${GITHUB_REF_NAME:-}}"
readonly REPOSITORY="${GITHUB_REPOSITORY:-mstallone/mx-master-input}"
readonly OUT="${RELEASE_OUTPUT_DIR:-$ROOT/dist}"
readonly GENERATE_APPCAST="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "release tag must use the form v1.2.3"
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || fail "SPARKLE_ED_PRIVATE_KEY is required"
[[ -x "$GENERATE_APPCAST" ]] || fail "Sparkle's generate_appcast is missing; run swift build first"
readonly VERSION="${RELEASE_TAG#v}"
readonly ARCHIVE="$OUT/MXMasterInput-$VERSION-macOS.zip"
readonly APPCAST="$OUT/appcast.xml"
readonly DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/"
[[ -f "$ARCHIVE" ]] || fail "release archive not found: $ARCHIVE"

printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$GENERATE_APPCAST" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG" \
  --maximum-versions 1 --maximum-deltas 0 --disable-signing-warning \
  -o "$APPCAST" "$OUT"

xmllint --noout "$APPCAST"
grep -Fq "<sparkle:version>$VERSION</sparkle:version>" "$APPCAST" || fail "appcast does not contain version $VERSION"
grep -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" || fail "appcast does not contain short version $VERSION"
grep -Fq 'sparkle:edSignature=' "$APPCAST" || fail "appcast archive is not signed"
grep -Fq "$DOWNLOAD_PREFIX$(basename "$ARCHIVE")" "$APPCAST" || fail "appcast download URL is incorrect"
printf 'Sparkle appcast: %s\n' "$APPCAST"
