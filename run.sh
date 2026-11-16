#!/bin/sh
# Build Kopumi.app and launch it. Usage: ./run.sh [release]
set -e
cd "$(dirname "$0")"
CONF=${1:-debug}
swift build -c "$CONF"

APP=.build/Kopumi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONF/Kopumi" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.daliys.kopumi</string>
  <key>CFBundleName</key><string>Kopumi</string>
  <key>CFBundleExecutable</key><string>Kopumi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# ponytail: ad-hoc signature → macOS may re-ask for Accessibility after rebuilds; use a Developer ID cert when that gets annoying
codesign --force --sign - "$APP"

pkill -x Kopumi || true
# Run binary directly so print() logs show in this terminal
"$APP/Contents/MacOS/Kopumi"
