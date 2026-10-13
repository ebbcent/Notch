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
cp Resources/notch-hook.sh "$APP/Contents/Resources/notch-hook.sh"
chmod +x "$APP/Contents/Resources/notch-hook.sh"

# App icon from Resources/AppIcon.png (1024 px).
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

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
