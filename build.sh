#!/bin/sh
# Builds MdChat.app. Usage: ./build.sh [debug|release]
set -eu

CONFIG="${1:-release}"
APP="MdChat.app"

if [ ! -f Sources/MdChat/Resources/vendor/markdown-it.min.js ]; then
  echo "vendor/ is empty — run ./fetch-deps.sh first" >&2
  exit 1
fi

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/MdChat" "$APP/Contents/MacOS/MdChat"
cp -R "$BIN_DIR/MdChat_MdChat.bundle" "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"

if [ -f Icon/AppIcon.icns ]; then
  cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "note: Icon/AppIcon.icns missing, app will use the generic icon" >&2
fi

# Ad-hoc signature so Keychain access and the network entitlement behave.
codesign --force --sign - --identifier com.local.mdchat "$APP" >/dev/null

echo "built $APP — open it with: open $APP"
