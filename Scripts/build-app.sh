#!/bin/bash
# Stages MXMasterInput.app from a built binary, with Sparkle embedded. Used by build.sh (local) and
# build-release.sh (CI). Signing is left to the caller (Scripts/sign.sh).
#   Scripts/build-app.sh <binary> <output.app> [version]
# The version defaults to the nearest tag. It is both CFBundleShortVersionString and CFBundleVersion,
# which is what Sparkle compares.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:?path to the built MXMasterInput binary}"
APP="${2:?output .app path}"
VERSION="${3:-$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
SPARKLE="$(dirname "$BINARY")/Sparkle.framework"
[[ -d "$SPARKLE" ]] || { echo "error: $SPARKLE not found next to the binary" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
# SwiftPM stamps the deployment target as the SDK version. AppKit keys modern control styling off that
# stamp, so restamp it with the SDK actually used, keeping the deployment target.
SDK="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos 26.0 "$SDK" -replace -output "$APP/Contents/MacOS/MXMasterInput" "$BINARY"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/MXMasterInput" 2>/dev/null
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" >"$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
echo "staged $APP ($VERSION)"
