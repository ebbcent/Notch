#!/bin/bash
# Builds build/Notch.app.  Usage:
#   ./build.sh          build only
#   ./build.sh run      build, copy to /Applications, (re)launch
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Notch.app
BUNDLE_ID=local.notch.island
IDENTITY="${NOTCH_SIGN_IDENTITY:-Notch Local}"

swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Notch" "$APP/Contents/MacOS/Notch"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A stable signing identity keeps macOS permissions between builds.
# Ad-hoc ("-") works, but macOS will ask for permissions again after each rebuild.
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    SIGN="$IDENTITY"
else
    SIGN="-"
    echo "warning: no \"$IDENTITY\" certificate found, signing ad-hoc (see README)."
fi
codesign --force --sign "$SIGN" --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP (signed with: $SIGN)"

if [[ "${1:-}" == "run" ]]; then
    pkill -x Notch 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Notch.app
    cp -R "$APP" /Applications/Notch.app
    open /Applications/Notch.app
    echo "Launched /Applications/Notch.app"
fi
