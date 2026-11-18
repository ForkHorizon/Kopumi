#!/bin/sh
# Ship Kopumi: release build → Developer ID signature (hardened runtime) → DMG → notarize → staple.
# Usage: ./release.sh 0.2
#        SKIP_NOTARIZE=1 SIGN_ID=- ./release.sh 0.2   (dry run: no Apple account needed)
#
# One-time setup (needs a paid Apple Developer Program membership):
#  1. Create a "Developer ID Application" certificate (developer.apple.com → Certificates, or
#     Xcode → Settings → Accounts → Manage Certificates) so it lands in your login keychain.
#  2. Store notarization credentials once (app-specific password from account.apple.com):
#       xcrun notarytool store-credentials kopumi-notary --apple-id <you> --team-id <TEAMID>
set -e
cd "$(dirname "$0")"
VERSION=${1:?usage: ./release.sh <version>, e.g. ./release.sh 0.2}
PROFILE=${NOTARY_PROFILE:-kopumi-notary}
DEV_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
SIGN_ID=${SIGN_ID:-$DEV_ID}
if [ -z "$SIGN_ID" ]; then
  echo "No \"Developer ID Application\" certificate in your keychain (see setup in $0)." >&2
  exit 1
fi
TIMESTAMP=--timestamp
if [ -n "$SKIP_NOTARIZE" ]; then
  TIMESTAMP=  # ad-hoc dry runs can't be timestamped
elif ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "No notarization credentials named \"$PROFILE\" (see setup in $0)." >&2
  exit 1
fi

VERSION=$VERSION SIGN_ID=$SIGN_ID CODESIGN_FLAGS="--options runtime $TIMESTAMP" NO_LAUNCH=1 \
  ./run.sh release
.build/release/Kopumi --check  # release build must pass the self-checks too (bare binary: its own prefs)

DMG=.build/Kopumi-$VERSION.dmg
STAGE=.build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R .build/Kopumi.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"  # drag-to-install
diskutil image create from --format UDZO --volumeName "Kopumi $VERSION" "$STAGE" "$DMG" >/dev/null
# shellcheck disable=SC2086 # TIMESTAMP may be empty
codesign --sign "$SIGN_ID" $TIMESTAMP "$DMG"

if [ -n "$SKIP_NOTARIZE" ]; then
  echo "Built $DMG (dry run: not notarized)"
  exit 0
fi
# ponytail: notarizes the DMG only (Apple checks the app inside); the app's ticket is fetched
# online on first launch. Staple the .app too if offline first launch ever matters.
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Ready to ship: $DMG"
