#!/bin/bash
# Signs MXMasterInput.app inside out: Sparkle's helpers, Sparkle, then the app. Sparkle ships ad-hoc
# signed helpers, which a Developer ID app can't load, and --deep would drop the Downloader's entitlements.
#   Scripts/sign.sh <app> <identity> [extra codesign flags...]
set -euo pipefail
APP="${1:?app path}"
IDENTITY="${2:?signing identity, or - for ad hoc}"
shift 2
sign=(codesign --force --sign "$IDENTITY" "$@")
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

"${sign[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${sign[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${sign[@]}" "$SPARKLE/Autoupdate"
"${sign[@]}" "$SPARKLE/Updater.app"
"${sign[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${sign[@]}" --identifier com.mattstallone.mxmasterinput "$APP"
codesign --verify --deep --strict "$APP"
