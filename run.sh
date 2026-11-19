#!/bin/sh
# Build Kopumi.app and launch it. Usage: ./run.sh [release]
#   SIGN_ID=…        signing identity (default: your "Apple Development" cert, else ad-hoc).
#                    A real identity keeps macOS's Accessibility grant across rebuilds.
#   CODESIGN_FLAGS=… extra codesign flags (release.sh passes hardened runtime + timestamp)
#   VERSION=…        CFBundleShortVersionString (default 0.1)
#   NO_LAUNCH=1      build and sign only
set -e
cd "$(dirname "$0")"
CONF=${1:-debug}
swift build -c "$CONF"

APP=.build/Kopumi.app
# Stop the running copy before its bundle is replaced: a process whose bundle changed on disk
# loses macOS's trust while its key tap is still installed, and that stalls input system-wide.
[ -n "$NO_LAUNCH" ] || pkill -x Kopumi || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONF/Kopumi" "$APP/Contents/MacOS/"
# Icon master: `.build/debug/Kopumi --icon icon.png`, then sips + iconutil into Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.daliys.kopumi</string>
  <key>CFBundleName</key><string>Kopumi</string>
  <key>CFBundleExecutable</key><string>Kopumi</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.1}</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
DEV_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
SIGN_ID=${SIGN_ID:-${DEV_ID:--}}
# shellcheck disable=SC2086 # CODESIGN_FLAGS is a list of flags
codesign --force --sign "$SIGN_ID" $CODESIGN_FLAGS "$APP"
echo "Signed with: $SIGN_ID"
[ -n "$NO_LAUNCH" ] && exit 0

# Run binary directly so print() logs show in this terminal
"$APP/Contents/MacOS/Kopumi"
