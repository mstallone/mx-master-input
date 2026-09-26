#!/bin/zsh
# Local development install: builds MXSwipe.app, signs it with your Apple Development identity (so
# the Accessibility grant survives rebuilds), installs it to /Applications, and relaunches it. Releases
# are built by CI from a tag (see README).
#   ./build.sh            build, install, launch
#   ./build.sh --no-launch
#   ./build.sh --replace  also overwrite a Developer ID (release) copy in /Applications
set -euo pipefail
cd "$(dirname "$0")"
APP=/Applications/MXSwipe.app

# grep without -q: with pipefail, -q would exit early and turn codesign's broken pipe into a false negative.
if [[ -d "$APP" && "$*" != *--replace* ]] && codesign -dvv "$APP" 2>&1 | grep '^Authority=Developer ID Application' >/dev/null; then
  echo "$APP is a release build. Pass --replace to overwrite it with a development build." >&2
  exit 1
fi

swift build -c release
Scripts/build-app.sh "$(swift build -c release --show-bin-path)/MXSwipe" .build/MXSwipe.app
# Apple Development only: a Developer ID signature would make the check above treat this build as a release.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Apple Development[^"]*"' | head -1 | tr -d '"')"
Scripts/sign.sh .build/MXSwipe.app "${SIGN_ID:--}"

pkill -x MXSwipe 2>/dev/null && sleep 0.4 || true
rm -rf "$APP" && cp -R .build/MXSwipe.app "$APP"
[[ "$*" == *--no-launch* ]] || open -a "$APP"
echo "MXSwipe installed at $APP (signed: ${SIGN_ID:-ad hoc})"
